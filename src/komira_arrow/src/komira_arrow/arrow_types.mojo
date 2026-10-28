# =============================================================================
# ArrowType — Arrow logical type enum covering the full Arrow type system
# =============================================================================
#
# Arrow's type system extends beyond numeric DTypes to include strings, binary,
# temporal types, nested types (list, struct), and dictionary encoding.
# This enum provides a uniform type identifier for Schema/Field metadata,
# decoupled from Mojo's DType which only covers fixed-width numerics.
# =============================================================================

# =============================================================================
# PHYSICAL LAYOUT CLASSES — what a type tag says about the BUFFERS.
# =============================================================================
#
# A logical Arrow type answers "what does this value MEAN"; a physical layout
# class answers "how many bytes per element, and which buffer holds them".
# Reinterpreting a column under a tag from a DIFFERENT class is the shape that
# produced the B-5 SEGFAULT (a DICTIONARY column's int32 codes read as string
# offsets — `tests/test_b5_segfault.mojo`) and is what makes an int32-offset
# consumer wrong for a `LARGE_STRING` column.
#
# `ARROW_LAYOUT_UNKNOWN` is 0 and means "the tag alone does not determine the
# layout". It is the SAFE value: every consumer treats it as "cannot conclude
# a conflict", never as "conflicts with everything".
# =============================================================================

comptime ARROW_LAYOUT_UNKNOWN: Int = 0
comptime ARROW_LAYOUT_BITMAP: Int = 1  # BOOL — 1 bit per value
comptime ARROW_LAYOUT_FIXED_1: Int = 2
comptime ARROW_LAYOUT_FIXED_2: Int = 3
comptime ARROW_LAYOUT_FIXED_4: Int = 4
comptime ARROW_LAYOUT_FIXED_8: Int = 5
comptime ARROW_LAYOUT_FIXED_16: Int = 6
comptime ARROW_LAYOUT_FIXED_32: Int = 7
comptime ARROW_LAYOUT_OFFSETS_I32: Int = 8  # STRING / BINARY
comptime ARROW_LAYOUT_OFFSETS_I64: Int = 9  # LARGE_STRING / LARGE_BINARY
comptime ARROW_LAYOUT_VIEW_16: Int = 10  # UTF8_VIEW / BINARY_VIEW
comptime ARROW_LAYOUT_DICTIONARY: Int = 11
comptime ARROW_LAYOUT_LIST_I32: Int = 12  # LIST / MAP
comptime ARROW_LAYOUT_LIST_I64: Int = 13  # LARGE_LIST
comptime ARROW_LAYOUT_STRUCT: Int = 14


@always_inline
def widen_offset_type(a: ArrowType) -> ArrowType:
    """The Int64-offset sibling of an Int32-offset varlen type; else `a`.

    ONE DEFINITION of the narrow -> wide mapping, because the Int32-offset
    promotion applies it at several producer
    sites and a second spelling would be a second chance to widen a BUFFER
    without widening the TAG.

    ⚠ THE ARROW SPEC DOES NOT GIVE EVERY OFFSET-BEARING LAYOUT A WIDE
    SIBLING, so this is deliberately a THREE-case mapping and not a general
    one:

      * `STRING` -> `LARGE_STRING`  (C-Data `"u"` -> `"U"`)
      * `BINARY` -> `LARGE_BINARY`  (C-Data `"z"` -> `"Z"`)
      * `LIST`   -> `LARGE_LIST`    (C-Data `"+l"` -> `"+L"`)
      * everything else -> ITSELF.

    `MAP` (`"+m"`) has **no** wide variant in the Arrow columnar spec at all
    — its offsets are permanently Int32 — so a map column cannot be promoted
    and must keep raising at the ceiling. Returning `a` unchanged is what
    makes that safe here: a producer that widened a MAP buffer would get a tag
    still saying MAP, so the layout-conflict guard fires instead of a wide tag
    describing a layout Arrow does not define. The same holds for the view
    layouts, which carry no offsets buffer to widen.

    Args:
        a: The type tag a producer is about to stamp on a widened buffer.

    Returns:
        The Int64-offset sibling when the spec defines one, else `a`.
    """
    if a == ArrowType.STRING:
        return ArrowType.LARGE_STRING
    if a == ArrowType.BINARY:
        return ArrowType.LARGE_BINARY
    if a == ArrowType.LIST:
        return ArrowType.LARGE_LIST
    return a


@always_inline
def layouts_conflict(a: ArrowType, b: ArrowType) -> Bool:
    """True iff `a` and `b` are KNOWN to describe incompatible buffer layouts.

    Conservative BY CONSTRUCTION: an `ARROW_LAYOUT_UNKNOWN` on either side
    returns False. A guard built on this can under-fire (miss a conflict it
    cannot prove) but can never over-fire on a type whose layout this file
    does not model — including `NULL`, whose mismatch-with-anything is the
    `Column` MOVE defect's signature and must stay repairable.

    Args:
        a: One type tag.
        b: The other type tag.

    Returns:
        True only when both classes are known AND differ.
    """
    var ca = a.physical_layout_class()
    var cb = b.physical_layout_class()
    if ca == ARROW_LAYOUT_UNKNOWN or cb == ARROW_LAYOUT_UNKNOWN:
        return False
    return ca != cb


struct ArrowType(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Arrow logical type — covers the full Arrow type system.

    Each type is identified by a UInt8 type_id. Named constants are provided
    for all standard Arrow types. ImplicitlyCopyable so that comptime
    constants (e.g., ArrowType.INT64) can be used in runtime expressions.

    Fields:
        type_id: Numeric identifier for this Arrow type.
    """

    var type_id: UInt8

    # --- Null ---
    comptime NULL = ArrowType(0)

    # --- Boolean ---
    comptime BOOL = ArrowType(1)

    # --- Signed integers ---
    comptime INT8 = ArrowType(2)
    comptime INT16 = ArrowType(3)
    comptime INT32 = ArrowType(4)
    comptime INT64 = ArrowType(5)

    # --- Unsigned integers ---
    comptime UINT8 = ArrowType(6)
    comptime UINT16 = ArrowType(7)
    comptime UINT32 = ArrowType(8)
    comptime UINT64 = ArrowType(9)

    # --- Floating point ---
    comptime FLOAT16 = ArrowType(10)
    comptime FLOAT32 = ArrowType(11)
    comptime FLOAT64 = ArrowType(12)

    # --- Variable-length ---
    comptime STRING = ArrowType(13)   # Utf8 with Int32 offsets
    comptime BINARY = ArrowType(14)   # Variable-length bytes with Int32 offsets

    # --- Temporal ---
    comptime DATE32 = ArrowType(15)   # days since epoch (Int32)
    comptime DATE64 = ArrowType(16)   # milliseconds since epoch (Int64)
    comptime TIMESTAMP = ArrowType(17)  # microseconds since epoch (Int64) — default/legacy
    comptime TIMESTAMP_S = ArrowType(22)   # seconds since epoch (Int64)
    comptime TIMESTAMP_MS = ArrowType(23)  # milliseconds since epoch (Int64)
    comptime TIMESTAMP_US = ArrowType(24)  # microseconds since epoch (Int64)
    comptime TIMESTAMP_NS = ArrowType(25)  # nanoseconds since epoch (Int64)

    # --- Decimal ---
    comptime DECIMAL128 = ArrowType(18)  # 128-bit fixed-point decimal

    # --- Large variable-length ---
    comptime LARGE_STRING = ArrowType(26)  # Utf8 with Int64 offsets (>2 GB)
    comptime LARGE_BINARY = ArrowType(27)  # Variable-length bytes with Int64 offsets (>2 GB)

    # --- Nested / encoded ---
    comptime DICTIONARY = ArrowType(19)  # Dictionary-encoded column
    comptime LIST = ArrowType(20)        # Variable-length list of a child type
    comptime STRUCT = ArrowType(21)      # Fixed set of named child fields
    comptime MAP = ArrowType(28)         # Map of key-value pairs (List<Struct{key,value}>)

    # --- Decimal (256-bit) ---
    comptime DECIMAL256 = ArrowType(29)  # 256-bit fixed-point decimal

    # --- Time (no date component) ---
    # Time32 — Int32 buffer (seconds or milliseconds since midnight).
    comptime TIME32_S = ArrowType(30)
    comptime TIME32_MS = ArrowType(31)
    # Time64 — Int64 buffer (microseconds or nanoseconds since midnight).
    comptime TIME64_US = ArrowType(32)
    comptime TIME64_NS = ArrowType(33)

    # --- Duration ---
    # Duration — Int64 buffer (elapsed time in the given unit). No tz.
    comptime DURATION_S = ArrowType(34)
    comptime DURATION_MS = ArrowType(35)
    comptime DURATION_US = ArrowType(36)
    comptime DURATION_NS = ArrowType(37)

    # --- Interval ---
    # Interval — calendar interval. Three sub-variants per Arrow spec:
    #   - year-month: Int32 (months)
    #   - day-time:   2× Int32 (days, milliseconds)
    #   - month-day-nano: Int32 + Int32 + Int64 (months, days, nanoseconds)
    comptime INTERVAL_YEAR_MONTH = ArrowType(38)
    comptime INTERVAL_DAY_TIME = ArrowType(39)
    comptime INTERVAL_MONTH_DAY_NANO = ArrowType(40)

    # --- Union ---
    # Union — multi-type column with a per-element Int8 type-id buffer.
    #   - sparse: each child has length N (the union length); no offsets.
    #   - dense:  each child holds only its own values; Int32 offsets buffer.
    comptime UNION_SPARSE = ArrowType(41)
    comptime UNION_DENSE = ArrowType(42)

    # LARGE_LIST — list-of-T with Int64 offsets (supports >2 GB total
    # length; otherwise LIST with Int32 offsets is preferred).
    comptime LARGE_LIST = ArrowType(43)

    # FIXED_SIZE_BINARY — fixed-width N-byte rows (no offsets buffer).
    # Underlying storage for Decimal128 (16 bytes) / Decimal256 (32 bytes)
    # / IntervalMonthDayNano (16 bytes) per Arrow spec; this arm exposes
    # the generic byte_width via Column._inner_size for pyarrow
    # pa.binary(N) interop.
    comptime FIXED_SIZE_BINARY = ArrowType(44)

    # FIXED_SIZE_LIST — list-of-T with FIXED inner element count per row
    # (no offsets buffer). Common for tensor-shape data
    # (e.g. FIXED_SIZE_LIST<Float32>(N) for N-D embeddings). Inner count
    # via Column._inner_size.
    comptime FIXED_SIZE_LIST = ArrowType(45)

    # View types (Arrow v0.15+). Wire format:
    #   - {Binary,Utf8}View: validity + 16-byte view buffer (per-cell:
    #     length:i32 + [4-byte prefix + 4-byte buf_idx + 4-byte offset]
    #     OR [12 inline bytes when length ≤ 12]) + N variadic data
    #     buffers (count carried on RecordBatch.variadicBufferCounts).
    #   - {List,LargeList}View: validity + offsets buffer (Int32/Int64
    #     non-cumulative) + sizes buffer (Int32/Int64 size-per-row) +
    #     1 child column.
    #
    # These ArrowType constants exist; the encoder raises for them ("view
    # encode is not supported"), and the decoder lossy-decodes view bytes
    # into expanded BINARY/STRING/LIST/LARGE_LIST (RecordBatch
    # variadicBufferCounts plumbing + per-cell view parse loop).
    comptime BINARY_VIEW = ArrowType(46)
    comptime UTF8_VIEW = ArrowType(47)
    comptime LIST_VIEW = ArrowType(48)
    comptime LARGE_LIST_VIEW = ArrowType(49)

    # --- Lifecycle ---

    def __init__(out self, type_id: UInt8):
        """Create an ArrowType from a numeric type_id."""
        self.type_id = type_id

    def __init__(out self, type_id: Int):
        """Create an ArrowType from an Int (convenience)."""
        self.type_id = UInt8(type_id)

    # --- Equatable ---

    @always_inline
    def __eq__(self, other: ArrowType) -> Bool:
        """Two ArrowTypes are equal if their type_ids match."""
        return self.type_id == other.type_id

    @always_inline
    def __ne__(self, other: ArrowType) -> Bool:
        """Two ArrowTypes are not equal if their type_ids differ."""
        return self.type_id != other.type_id

    # --- Writable ---

    def write_to[W: Writer](self, mut writer: W):
        """Write a human-readable name for the type."""
        if self == ArrowType.NULL:
            writer.write("null")
        elif self == ArrowType.BOOL:
            writer.write("bool")
        elif self == ArrowType.INT8:
            writer.write("int8")
        elif self == ArrowType.INT16:
            writer.write("int16")
        elif self == ArrowType.INT32:
            writer.write("int32")
        elif self == ArrowType.INT64:
            writer.write("int64")
        elif self == ArrowType.UINT8:
            writer.write("uint8")
        elif self == ArrowType.UINT16:
            writer.write("uint16")
        elif self == ArrowType.UINT32:
            writer.write("uint32")
        elif self == ArrowType.UINT64:
            writer.write("uint64")
        elif self == ArrowType.FLOAT16:
            writer.write("float16")
        elif self == ArrowType.FLOAT32:
            writer.write("float32")
        elif self == ArrowType.FLOAT64:
            writer.write("float64")
        elif self == ArrowType.STRING:
            writer.write("string")
        elif self == ArrowType.BINARY:
            writer.write("binary")
        elif self == ArrowType.LARGE_STRING:
            writer.write("large_string")
        elif self == ArrowType.LARGE_BINARY:
            writer.write("large_binary")
        elif self == ArrowType.DATE32:
            writer.write("date32")
        elif self == ArrowType.DATE64:
            writer.write("date64")
        elif self == ArrowType.TIMESTAMP:
            writer.write("timestamp[us]")
        elif self == ArrowType.TIMESTAMP_S:
            writer.write("timestamp[s]")
        elif self == ArrowType.TIMESTAMP_MS:
            writer.write("timestamp[ms]")
        elif self == ArrowType.TIMESTAMP_US:
            writer.write("timestamp[us]")
        elif self == ArrowType.TIMESTAMP_NS:
            writer.write("timestamp[ns]")
        elif self == ArrowType.DECIMAL128:
            writer.write("decimal128")
        elif self == ArrowType.DICTIONARY:
            writer.write("dictionary")
        elif self == ArrowType.LIST:
            writer.write("list")
        elif self == ArrowType.LARGE_LIST:
            writer.write("large_list")
        elif self == ArrowType.FIXED_SIZE_BINARY:
            writer.write("fixed_size_binary")
        elif self == ArrowType.FIXED_SIZE_LIST:
            writer.write("fixed_size_list")
        elif self == ArrowType.BINARY_VIEW:
            writer.write("binary_view")
        elif self == ArrowType.UTF8_VIEW:
            writer.write("utf8_view")
        elif self == ArrowType.LIST_VIEW:
            writer.write("list_view")
        elif self == ArrowType.LARGE_LIST_VIEW:
            writer.write("large_list_view")
        elif self == ArrowType.STRUCT:
            writer.write("struct")
        elif self == ArrowType.MAP:
            writer.write("map")
        elif self == ArrowType.DECIMAL256:
            writer.write("decimal256")
        elif self == ArrowType.TIME32_S:
            writer.write("time32[s]")
        elif self == ArrowType.TIME32_MS:
            writer.write("time32[ms]")
        elif self == ArrowType.TIME64_US:
            writer.write("time64[us]")
        elif self == ArrowType.TIME64_NS:
            writer.write("time64[ns]")
        elif self == ArrowType.DURATION_S:
            writer.write("duration[s]")
        elif self == ArrowType.DURATION_MS:
            writer.write("duration[ms]")
        elif self == ArrowType.DURATION_US:
            writer.write("duration[us]")
        elif self == ArrowType.DURATION_NS:
            writer.write("duration[ns]")
        elif self == ArrowType.INTERVAL_YEAR_MONTH:
            writer.write("interval[year_month]")
        elif self == ArrowType.INTERVAL_DAY_TIME:
            writer.write("interval[day_time]")
        elif self == ArrowType.INTERVAL_MONTH_DAY_NANO:
            writer.write("interval[month_day_nano]")
        elif self == ArrowType.UNION_SPARSE:
            writer.write("union[sparse]")
        elif self == ArrowType.UNION_DENSE:
            writer.write("union[dense]")
        else:
            writer.write("unknown(", String(Int(self.type_id)), ")")

    # --- Query helpers ---

    @always_inline
    def is_integer(self) -> Bool:
        """True if this is a signed or unsigned integer type."""
        return (
            self.type_id >= ArrowType.INT8.type_id
            and self.type_id <= ArrowType.UINT64.type_id
        )

    @always_inline
    def is_floating(self) -> Bool:
        """True if this is a floating-point type."""
        return (
            self.type_id >= ArrowType.FLOAT16.type_id
            and self.type_id <= ArrowType.FLOAT64.type_id
        )

    @always_inline
    def is_numeric(self) -> Bool:
        """True if this is a numeric type (integer or floating-point)."""
        return self.is_integer() or self.is_floating()

    @always_inline
    def is_temporal(self) -> Bool:
        """True if this is a temporal type (date, time, timestamp, duration, interval)."""
        return (
            (self.type_id >= ArrowType.DATE32.type_id
            and self.type_id <= ArrowType.TIMESTAMP.type_id)
            or self.is_timestamp()
            or self.is_time()
            or self.is_duration()
            or self.is_interval()
        )

    @always_inline
    def is_time(self) -> Bool:
        """True if this is a Time32 or Time64 type."""
        return (
            self == ArrowType.TIME32_S
            or self == ArrowType.TIME32_MS
            or self == ArrowType.TIME64_US
            or self == ArrowType.TIME64_NS
        )

    @always_inline
    def is_duration(self) -> Bool:
        """True if this is any Duration type."""
        return (
            self == ArrowType.DURATION_S
            or self == ArrowType.DURATION_MS
            or self == ArrowType.DURATION_US
            or self == ArrowType.DURATION_NS
        )

    @always_inline
    def is_interval(self) -> Bool:
        """True if this is any Interval type."""
        return (
            self == ArrowType.INTERVAL_YEAR_MONTH
            or self == ArrowType.INTERVAL_DAY_TIME
            or self == ArrowType.INTERVAL_MONTH_DAY_NANO
        )

    @always_inline
    def is_union(self) -> Bool:
        """True if this is a sparse or dense Union type."""
        return self == ArrowType.UNION_SPARSE or self == ArrowType.UNION_DENSE

    @always_inline
    def is_timestamp(self) -> Bool:
        """True if this is any timestamp type (s/ms/us/ns or legacy)."""
        return (
            self == ArrowType.TIMESTAMP
            or self == ArrowType.TIMESTAMP_S
            or self == ArrowType.TIMESTAMP_MS
            or self == ArrowType.TIMESTAMP_US
            or self == ArrowType.TIMESTAMP_NS
        )

    @always_inline
    def is_nested(self) -> Bool:
        """True if this is a nested type (list/large_list/fixed_size_list,
        struct, or map). FIXED_SIZE_BINARY is NOT nested — it's a
        fixed-width primitive (no children)."""
        return (
            self == ArrowType.LIST
            or self == ArrowType.LARGE_LIST
            or self == ArrowType.FIXED_SIZE_LIST
            or self == ArrowType.STRUCT
            or self == ArrowType.MAP
        )

    @always_inline
    def physical_layout_class(self) -> Int:
        """The BUFFER LAYOUT this type's columns are stored in — the thing a
        reinterpretation of the type tag actually changes.

        Two types share a class iff a Column carrying one can be READ through
        the accessor for the other and yield the same bytes. `DATE32` and
        `INT32` share a class (both a 4-byte fixed-width values buffer);
        `STRING` and `LARGE_STRING` do NOT (int32 vs int64 offsets), and
        neither do `STRING` and `DICTIONARY` (per-row offsets addressing the
        value bytes vs int32 codes addressing a shared dictionary).

        ⚠ `ARROW_LAYOUT_UNKNOWN` is returned for every type whose layout is
        NOT a property of the tag alone (`FIXED_SIZE_BINARY` /
        `FIXED_SIZE_LIST` carry their width per-column in `_inner_size`), for
        the ones this project does not model yet (unions, list views), and —
        deliberately — for `NULL`. Callers use this to REJECT, so an
        `UNKNOWN` on either side must never produce a rejection; see
        `layouts_conflict` below. `NULL` is `UNKNOWN` because a zeroed
        `arrow_type` is the signature of the `Column` MOVE defect (the tag
        "reads as 0 (which maps to `ArrowType.NULL`)"), and the schema-repair that
        recovers from it must keep working.

        Returns:
            An `ARROW_LAYOUT_*` class id; `ARROW_LAYOUT_UNKNOWN` (0) when the
            tag alone does not determine the layout.
        """
        # --- No buffers / not tag-determined. See the docstring: 0 is the
        # "do not reject on this" value, and NULL lives here on purpose.
        if self == ArrowType.NULL:
            return ARROW_LAYOUT_UNKNOWN

        # --- Bit-packed ---
        if self == ArrowType.BOOL:
            return ARROW_LAYOUT_BITMAP

        # --- Fixed-width values buffers, keyed on element WIDTH ---
        if self == ArrowType.INT8 or self == ArrowType.UINT8:
            return ARROW_LAYOUT_FIXED_1
        if (
            self == ArrowType.INT16
            or self == ArrowType.UINT16
            or self == ArrowType.FLOAT16
        ):
            return ARROW_LAYOUT_FIXED_2
        if (
            self == ArrowType.INT32
            or self == ArrowType.UINT32
            or self == ArrowType.FLOAT32
            or self == ArrowType.DATE32
            or self == ArrowType.TIME32_S
            or self == ArrowType.TIME32_MS
            or self == ArrowType.INTERVAL_YEAR_MONTH
        ):
            return ARROW_LAYOUT_FIXED_4
        if (
            self == ArrowType.INT64
            or self == ArrowType.UINT64
            or self == ArrowType.FLOAT64
            or self == ArrowType.DATE64
            or self.is_timestamp()
            or self == ArrowType.TIME64_US
            or self == ArrowType.TIME64_NS
            or self.is_duration()
            or self == ArrowType.INTERVAL_DAY_TIME
        ):
            return ARROW_LAYOUT_FIXED_8
        if (
            self == ArrowType.DECIMAL128
            or self == ArrowType.INTERVAL_MONTH_DAY_NANO
        ):
            return ARROW_LAYOUT_FIXED_16
        if self == ArrowType.DECIMAL256:
            return ARROW_LAYOUT_FIXED_32

        # --- Variable-length: THE OFFSET WIDTH IS THE WHOLE POINT ---
        if self == ArrowType.STRING or self == ArrowType.BINARY:
            return ARROW_LAYOUT_OFFSETS_I32
        if (
            self == ArrowType.LARGE_STRING
            or self == ArrowType.LARGE_BINARY
        ):
            return ARROW_LAYOUT_OFFSETS_I64

        # --- 16-byte inline/prefix records + variadic data buffers ---
        if self == ArrowType.UTF8_VIEW or self == ArrowType.BINARY_VIEW:
            return ARROW_LAYOUT_VIEW_16

        # --- Codes + a shared dictionary ---
        if self == ArrowType.DICTIONARY:
            return ARROW_LAYOUT_DICTIONARY

        # --- Nested ---
        if self == ArrowType.LIST or self == ArrowType.MAP:
            return ARROW_LAYOUT_LIST_I32
        if self == ArrowType.LARGE_LIST:
            return ARROW_LAYOUT_LIST_I64
        if self == ArrowType.STRUCT:
            return ARROW_LAYOUT_STRUCT

        # FIXED_SIZE_BINARY / FIXED_SIZE_LIST (width is per-column, not
        # per-tag), UNION_*, LIST_VIEW, LARGE_LIST_VIEW, ERROR, and anything
        # added later without a case here.
        return ARROW_LAYOUT_UNKNOWN

    # --- Conversion from DType ---

    def _write_format_string[W: Writer](self, mut writer: W):
        """WRITE what `format_string` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

        The arms live here so no string constant is ever SELECTED and
        returned. A literal-returning ladder lowers to two parallel
        (pointer, length) constant arrays whose two call-site references
        an `--emit shared-lib` link binds INDEPENDENTLY; a shared library
        whose link binds such a pair CROSSED takes the host interpreter
        down with it."""
        if self == ArrowType.NULL:
            writer.write("n")
            return
        elif self == ArrowType.BOOL:
            writer.write("b")
            return
        elif self == ArrowType.INT8:
            writer.write("c")
            return
        elif self == ArrowType.INT16:
            writer.write("s")
            return
        elif self == ArrowType.INT32:
            writer.write("i")
            return
        elif self == ArrowType.INT64:
            writer.write("l")
            return
        elif self == ArrowType.UINT8:
            writer.write("C")
            return
        elif self == ArrowType.UINT16:
            writer.write("S")
            return
        elif self == ArrowType.UINT32:
            writer.write("I")
            return
        elif self == ArrowType.UINT64:
            writer.write("L")
            return
        elif self == ArrowType.FLOAT16:
            writer.write("e")
            return
        elif self == ArrowType.FLOAT32:
            writer.write("f")
            return
        elif self == ArrowType.FLOAT64:
            writer.write("g")
            return
        elif self == ArrowType.STRING:
            writer.write("u")
            return
        elif self == ArrowType.BINARY:
            writer.write("z")
            return
        elif self == ArrowType.LARGE_STRING:
            writer.write("U")
            return
        elif self == ArrowType.LARGE_BINARY:
            writer.write("Z")
            return
        elif self == ArrowType.DATE32:
            writer.write("tdD")
            return
        elif self == ArrowType.DATE64:
            writer.write("tdm")
            return
        elif self == ArrowType.TIMESTAMP:
            # Legacy: microsecond precision, no timezone
            writer.write("tsu:")
            return
        elif self == ArrowType.TIMESTAMP_S:
            writer.write("tss:")
            return
        elif self == ArrowType.TIMESTAMP_MS:
            writer.write("tsm:")
            return
        elif self == ArrowType.TIMESTAMP_US:
            writer.write("tsu:")
            return
        elif self == ArrowType.TIMESTAMP_NS:
            writer.write("tsn:")
            return
        elif self == ArrowType.DECIMAL128:
            # Default precision=38, scale=18 — use decimal_format_string()
            # for actual precision/scale.
            writer.write("d:38,18")
            return
        elif self == ArrowType.LIST:
            writer.write("+l")
            return
        elif self == ArrowType.LARGE_LIST:
            writer.write("+L")
            return
        elif self == ArrowType.BINARY_VIEW:
            writer.write("vz")  # Arrow C Data Interface BinaryView format string
            return
        elif self == ArrowType.UTF8_VIEW:
            writer.write("vu")  # Arrow C Data Interface Utf8View format string
            return
        elif self == ArrowType.LIST_VIEW:
            writer.write("+vl")  # Arrow C Data Interface ListView format string
            return
        elif self == ArrowType.LARGE_LIST_VIEW:
            writer.write("+vL")  # Arrow C Data Interface LargeListView format string
            return
        elif self == ArrowType.STRUCT:
            writer.write("+s")
            return
        elif self == ArrowType.MAP:
            writer.write("+m")
            return
        elif self == ArrowType.DICTIONARY:
            # Dictionary index type is encoded separately; this is a
            # placeholder — callers should use the index type's format string.
            writer.write("i")
            return
        elif self == ArrowType.DECIMAL256:
            # Default precision=76 (max for 256-bit), scale=0 — use
            # decimal256_format_string() for actual precision/scale.
            writer.write("d:76,0,256")
            return
        elif self == ArrowType.TIME32_S:
            writer.write("tts")
            return
        elif self == ArrowType.TIME32_MS:
            writer.write("ttm")
            return
        elif self == ArrowType.TIME64_US:
            writer.write("ttu")
            return
        elif self == ArrowType.TIME64_NS:
            writer.write("ttn")
            return
        elif self == ArrowType.DURATION_S:
            writer.write("tDs")
            return
        elif self == ArrowType.DURATION_MS:
            writer.write("tDm")
            return
        elif self == ArrowType.DURATION_US:
            writer.write("tDu")
            return
        elif self == ArrowType.DURATION_NS:
            writer.write("tDn")
            return
        elif self == ArrowType.INTERVAL_YEAR_MONTH:
            writer.write("tiM")
            return
        elif self == ArrowType.INTERVAL_DAY_TIME:
            writer.write("tiD")
            return
        elif self == ArrowType.INTERVAL_MONTH_DAY_NANO:
            writer.write("tin")
            return
        elif self == ArrowType.UNION_SPARSE:
            # Union type-ids are parameterized; this is a placeholder —
            # use union_format_string() with the type-ids list.
            writer.write("+us:")
            return
        elif self == ArrowType.UNION_DENSE:
            # Union type-ids are parameterized; this is a placeholder —
            # use union_format_string() with the type-ids list.
            writer.write("+ud:")
            return
        else:
            writer.write("n")
            return

    def format_string(self) -> String:
        """Return the Arrow C Data Interface format string for this type.

        Format strings are defined by the Arrow C Data Interface specification
        and are used for zero-copy interchange between Arrow implementations.

        See: https://arrow.apache.org/docs/format/CDataInterface.html

        Returns:
            The single- or multi-character format string (e.g., "i" for INT32).
        """
        var out = String()
        self._write_format_string(out)
        return out^

    @staticmethod
    def from_dtype(dt: DType) -> ArrowType:
        """Convert a Mojo DType to the corresponding ArrowType.

        This covers the fixed-width numeric types that DType represents.
        For non-numeric Arrow types (string, binary, etc.), use the
        ArrowType constants directly.
        """
        if dt == DType.bool:
            return ArrowType.BOOL
        elif dt == DType.int8:
            return ArrowType.INT8
        elif dt == DType.int16:
            return ArrowType.INT16
        elif dt == DType.int32:
            return ArrowType.INT32
        elif dt == DType.int64:
            return ArrowType.INT64
        elif dt == DType.uint8:
            return ArrowType.UINT8
        elif dt == DType.uint16:
            return ArrowType.UINT16
        elif dt == DType.uint32:
            return ArrowType.UINT32
        elif dt == DType.uint64:
            return ArrowType.UINT64
        elif dt == DType.float16:
            return ArrowType.FLOAT16
        elif dt == DType.float32:
            return ArrowType.FLOAT32
        elif dt == DType.float64:
            return ArrowType.FLOAT64
        else:
            return ArrowType.NULL


# =============================================================================
# Standalone format-string helpers for parameterized types
# =============================================================================


def decimal_format_string(precision: Int, scale: Int) -> String:
    """Return the Arrow C Data Interface format string for Decimal128
    with the given precision and scale.

    The format string is "d:<precision>,<scale>" per the Arrow spec.

    Args:
        precision: Total number of digits (1-38).
        scale: Number of digits after the decimal point.

    Returns:
        The C Data Interface format string, e.g. "d:18,6".
    """
    return "d:" + String(precision) + "," + String(scale)


def timestamp_format_string(unit: String, timezone: String = "") -> String:
    """Return the Arrow C Data Interface format string for Timestamp
    with the given unit and optional timezone.

    The format string is "ts<unit>:<timezone>" per the Arrow spec.

    Args:
        unit: One of "s", "ms", "us", "ns".
        timezone: Optional IANA timezone string (e.g. "UTC", "America/New_York").
            Empty string means no timezone.

    Returns:
        The C Data Interface format string, e.g. "tsu:UTC".
    """
    return "ts" + unit + ":" + timezone


def decimal256_format_string(precision: Int, scale: Int) -> String:
    """Return the Arrow C Data Interface format string for Decimal256.

    The format string is "d:<precision>,<scale>,256" per the Arrow spec
    (the third comma-separated component is the bit-width).

    Args:
        precision: Total number of digits (1-76 for 256-bit).
        scale: Number of digits after the decimal point.

    Returns:
        The C Data Interface format string, e.g. "d:38,2,256".
    """
    return "d:" + String(precision) + "," + String(scale) + ",256"


def union_format_string(mode: ArrowType, type_ids: List[Int]) -> String:
    """Return the Arrow C Data Interface format string for a Union.

    Sparse: "+us:I,J,...". Dense: "+ud:I,J,...". Per the Arrow spec, the
    `mode` argument selects the prefix and `type_ids` is the comma-separated
    list of child type ids (matched against the run-time type-id buffer).

    Args:
        mode: ArrowType.UNION_SPARSE or ArrowType.UNION_DENSE.
        type_ids: The list of type ids (one per child, in child-order).

    Returns:
        The C Data Interface format string, e.g. "+us:0,1,2".
    """
    var prefix: String
    if mode == ArrowType.UNION_DENSE:
        prefix = "+ud:"
    else:
        # Default to sparse for any non-dense input.
        prefix = "+us:"
    var s = prefix
    for i in range(len(type_ids)):
        if i > 0:
            s = s + ","
        s = s + String(type_ids[i])
    return s


# =============================================================================
# Format-string parsing — Arrow C Data Interface → ArrowType (round-trip)
# =============================================================================
#
# The single-letter / short-prefix format strings in the Arrow spec map
# uniquely back to ArrowType slots. Parameterized strings ("d:P,S,256",
# "tsu:UTC", "+us:0,1") still parse to the right ArrowType slot; the
# precision/scale/timezone/type-ids ride in separate Field-level slots
# (filed for Phase B). Phase A's parser supports the discriminator-level
# round-trip needed for the format-string acceptance gate.


def parse_format_string(s: String) -> ArrowType:
    """Parse an Arrow C Data Interface format string back to ArrowType.

    Inverse of `ArrowType.format_string()` at the type-discriminator level.
    Parameterized prefixes (decimal, timestamp, union) parse to the
    ArrowType slot only; precision/scale/timezone/type-ids parsing is
    Phase-B work and uses the standalone helpers.

    Args:
        s: The format string, e.g. "i", "u", "tsu:UTC", "+us:0,1".

    Returns:
        The ArrowType slot. Returns `ArrowType.NULL` for unrecognized strings.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return ArrowType.NULL

    # --- Single-letter fixed-width types ---
    if n == 1:
        var c = bytes[0]
        if c == UInt8(ord("n")):
            return ArrowType.NULL
        elif c == UInt8(ord("b")):
            return ArrowType.BOOL
        elif c == UInt8(ord("c")):
            return ArrowType.INT8
        elif c == UInt8(ord("s")):
            return ArrowType.INT16
        elif c == UInt8(ord("i")):
            return ArrowType.INT32
        elif c == UInt8(ord("l")):
            return ArrowType.INT64
        elif c == UInt8(ord("C")):
            return ArrowType.UINT8
        elif c == UInt8(ord("S")):
            return ArrowType.UINT16
        elif c == UInt8(ord("I")):
            return ArrowType.UINT32
        elif c == UInt8(ord("L")):
            return ArrowType.UINT64
        elif c == UInt8(ord("e")):
            return ArrowType.FLOAT16
        elif c == UInt8(ord("f")):
            return ArrowType.FLOAT32
        elif c == UInt8(ord("g")):
            return ArrowType.FLOAT64
        elif c == UInt8(ord("u")):
            return ArrowType.STRING
        elif c == UInt8(ord("U")):
            return ArrowType.LARGE_STRING
        elif c == UInt8(ord("z")):
            return ArrowType.BINARY
        elif c == UInt8(ord("Z")):
            return ArrowType.LARGE_BINARY
        else:
            return ArrowType.NULL

    # --- Multi-character prefixes ---

    var b0 = bytes[0]

    # Temporal — Date, Time32/64, Timestamp, Duration, Interval all start with "t".
    if b0 == UInt8(ord("t")):
        if n < 3:
            return ArrowType.NULL
        var b1 = bytes[1]
        var b2 = bytes[2]
        if b1 == UInt8(ord("d")):
            # Date: "tdD" (day) or "tdm" (ms)
            if b2 == UInt8(ord("D")):
                return ArrowType.DATE32
            elif b2 == UInt8(ord("m")):
                return ArrowType.DATE64
            else:
                return ArrowType.NULL
        elif b1 == UInt8(ord("t")):
            # Time32 / Time64: "tts" "ttm" "ttu" "ttn"
            if b2 == UInt8(ord("s")):
                return ArrowType.TIME32_S
            elif b2 == UInt8(ord("m")):
                return ArrowType.TIME32_MS
            elif b2 == UInt8(ord("u")):
                return ArrowType.TIME64_US
            elif b2 == UInt8(ord("n")):
                return ArrowType.TIME64_NS
            else:
                return ArrowType.NULL
        elif b1 == UInt8(ord("s")):
            # Timestamp: "ts<unit>:<tz>" — the unit char drives the slot;
            # the timezone is parsed by callers via Phase-B Field plumbing.
            if b2 == UInt8(ord("s")):
                return ArrowType.TIMESTAMP_S
            elif b2 == UInt8(ord("m")):
                return ArrowType.TIMESTAMP_MS
            elif b2 == UInt8(ord("u")):
                return ArrowType.TIMESTAMP_US
            elif b2 == UInt8(ord("n")):
                return ArrowType.TIMESTAMP_NS
            else:
                return ArrowType.NULL
        elif b1 == UInt8(ord("D")):
            # Duration: "tDs" "tDm" "tDu" "tDn"
            if b2 == UInt8(ord("s")):
                return ArrowType.DURATION_S
            elif b2 == UInt8(ord("m")):
                return ArrowType.DURATION_MS
            elif b2 == UInt8(ord("u")):
                return ArrowType.DURATION_US
            elif b2 == UInt8(ord("n")):
                return ArrowType.DURATION_NS
            else:
                return ArrowType.NULL
        elif b1 == UInt8(ord("i")):
            # Interval: "tiM" "tiD" "tin"
            if b2 == UInt8(ord("M")):
                return ArrowType.INTERVAL_YEAR_MONTH
            elif b2 == UInt8(ord("D")):
                return ArrowType.INTERVAL_DAY_TIME
            elif b2 == UInt8(ord("n")):
                return ArrowType.INTERVAL_MONTH_DAY_NANO
            else:
                return ArrowType.NULL
        else:
            return ArrowType.NULL

    # Decimal — "d:<precision>,<scale>" or "d:<precision>,<scale>,<bitwidth>"
    if b0 == UInt8(ord("d")) and n >= 2 and bytes[1] == UInt8(ord(":")):
        # Decimal256 if the suffix ends with ",256"; otherwise Decimal128.
        # Phase-A discriminator-only parse; precision/scale ride in Phase B.
        if (
            n >= 6
            and bytes[n - 4] == UInt8(ord(","))
            and bytes[n - 3] == UInt8(ord("2"))
            and bytes[n - 2] == UInt8(ord("5"))
            and bytes[n - 1] == UInt8(ord("6"))
        ):
            return ArrowType.DECIMAL256
        return ArrowType.DECIMAL128

    # Nested — "+" prefix.
    if b0 == UInt8(ord("+")):
        if n < 2:
            return ArrowType.NULL
        var b1 = bytes[1]
        if b1 == UInt8(ord("l")):
            return ArrowType.LIST
        elif b1 == UInt8(ord("s")):
            return ArrowType.STRUCT
        elif b1 == UInt8(ord("m")):
            return ArrowType.MAP
        elif b1 == UInt8(ord("u")) and n >= 3:
            var b2 = bytes[2]
            if b2 == UInt8(ord("s")):
                # "+us:I,J,..." — sparse union.
                return ArrowType.UNION_SPARSE
            elif b2 == UInt8(ord("d")):
                # "+ud:I,J,..." — dense union.
                return ArrowType.UNION_DENSE
            else:
                return ArrowType.NULL
        else:
            return ArrowType.NULL

    return ArrowType.NULL


# =============================================================================
# Format-string parameter extraction — Phase B
# =============================================================================
#
# `parse_format_string` is discriminator-only (returns ArrowType).  These
# helpers extract the parameter payloads from the same format strings:
#   * `extract_decimal_params("d:38,2[,256]") -> (precision, scale, bitwidth)`
#   * `extract_timestamp_timezone("tsu:UTC") -> "UTC"`
#   * `extract_union_type_ids("+us:0,1,2") -> [0, 1, 2]`
# Each is total (defensively returns sensible defaults / empty on malformed
# input).  Phase B Field plumbing calls these when materializing Field params
# from incoming format strings.


def _parse_int_token(tok: String) -> Int:
    """Best-effort base-10 unsigned int parse; -1 if non-numeric / empty.

    Tolerates a leading sign char (Arrow union type-ids are non-negative per
    spec but accepting `-` is harmless on a defensive parser).
    """
    var bytes = tok.as_bytes()
    var n = len(bytes)
    if n == 0:
        return -1
    var i = 0
    var sign = 1
    if bytes[0] == UInt8(ord("-")):
        sign = -1
        i = 1
    elif bytes[0] == UInt8(ord("+")):
        i = 1
    if i >= n:
        return -1
    var v: Int = 0
    while i < n:
        var c = bytes[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return -1
        v = v * 10 + Int(c - UInt8(ord("0")))
        i += 1
    return v * sign


def extract_decimal_params(fmt: String) raises -> Tuple[Int, Int, Int]:
    """Extract `(precision, scale, bitwidth)` from a decimal format string.

    Spec: `d:P,S` (bitwidth implicit 128) or `d:P,S,W` (W in {128, 256}).
    Returns `(0, 0, 0)` on malformed input.  Bitwidth defaults to 128 when
    the third comma-separated component is absent.

    Examples:
        extract_decimal_params("d:18,6")   -> (18, 6, 128)
        extract_decimal_params("d:38,2,256") -> (38, 2, 256)
        extract_decimal_params("foo")      -> (0, 0, 0)
    """
    var bytes = fmt.as_bytes()
    if len(bytes) < 4:
        return (0, 0, 0)
    if bytes[0] != UInt8(ord("d")) or bytes[1] != UInt8(ord(":")):
        return (0, 0, 0)
    # Strip "d:" prefix by splitting on ':' (matches the c_data_stream idiom).
    var head_parts = fmt.split(":")
    if len(head_parts) < 2:
        return (0, 0, 0)
    var tail = String(head_parts[1])
    var parts = tail.split(",")
    if len(parts) < 2:
        return (0, 0, 0)
    var p = _parse_int_token(String(parts[0]))
    var s = _parse_int_token(String(parts[1]))
    if p < 0 or s < 0:
        return (0, 0, 0)
    var w: Int = 128
    if len(parts) >= 3:
        var w_parsed = _parse_int_token(String(parts[2]))
        if w_parsed > 0:
            w = w_parsed
    return (p, s, w)


def extract_timestamp_timezone(fmt: String) raises -> String:
    """Extract the timezone suffix from a timestamp format string.

    Spec: `tsX:<tz>` where X is in {s, m, u, n}.  Returns the substring
    after the first ':'.  An empty timezone (`tsu:`) returns `""`.
    Returns `""` for non-timestamp / malformed input.
    """
    var bytes = fmt.as_bytes()
    var n = len(bytes)
    if n < 3:
        return String("")
    # Must start with "ts".
    if bytes[0] != UInt8(ord("t")) or bytes[1] != UInt8(ord("s")):
        return String("")
    # Split on the FIRST ':'; the tz is everything after it.  Mojo's
    # `String.split(":")` splits on every ':' which is appropriate here
    # because IANA tz names contain at most one '/' but never ':'.
    var parts = fmt.split(":")
    if len(parts) < 2:
        return String("")
    return String(parts[1])


def extract_union_type_ids(fmt: String) raises -> List[Int]:
    """Extract the type-id list from a union format string.

    Spec: `+us:I,J,...` (sparse) or `+ud:I,J,...` (dense).  Returns a
    `List[Int]` of the parsed ids in declaration order.  Returns an empty
    list for non-union / malformed input.

    Examples:
        extract_union_type_ids("+us:0,1,2") -> [0, 1, 2]
        extract_union_type_ids("+ud:5,7")   -> [5, 7]
        extract_union_type_ids("+us:")      -> []
        extract_union_type_ids("foo")       -> []
    """
    var out = List[Int]()
    var bytes = fmt.as_bytes()
    var n = len(bytes)
    if n < 4:
        return out^
    # Must start with "+u" then 's' or 'd' then ':'.
    if bytes[0] != UInt8(ord("+")) or bytes[1] != UInt8(ord("u")):
        return out^
    if bytes[2] != UInt8(ord("s")) and bytes[2] != UInt8(ord("d")):
        return out^
    if bytes[3] != UInt8(ord(":")):
        return out^
    if n == 4:
        return out^
    # Split on the first ':'; the tail holds the comma-separated type ids.
    var head_parts = fmt.split(":")
    if len(head_parts) < 2:
        return out^
    var tail = String(head_parts[1])
    var parts = tail.split(",")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.byte_length() == 0:
            continue
        var v = _parse_int_token(p)
        if v >= 0:
            out.append(v)
    return out^




# =============================================================================
# arrow_fixed_byte_width — THE fixed-byte-width table. IT DOES NOT GUESS.
# =============================================================================
#
# ⛔ THERE IS NO `else: return 8` HERE, AND ADDING ONE BACK IS THE DEFECT.
#
#
# WHY IT LIVES IN `arrow_types.mojo`. The byte width of an ArrowType is a
# property OF the ArrowType, and this module is a LEAF — it imports nothing.
# Every consumer in the tree can therefore reach it, including the ones inside
# the core packages that cannot import the core packages
# (`arrow/__init__.mojo` imports `.concat`, and `compiler_helpers` imports
# `..arrow.schema`, so an `arrow/* -> helpers/*` edge closes a package-init
# cycle). That reachability is the whole point: every width helper consults
# this ONE table instead of keeping its own ladder, because independently
# maintained copies DRIFT — each with an `else: return 8` fallback that
# silently mis-sizes whatever it forgot (unsigned types, FLOAT16, DECIMAL128/
# 256, INTERVAL_MONTH_DAY_NANO, the temporal family), and a fix at one copy
# never reaches the others.
#
# ⚠ A width helper that ends in `return 0` — a sentinel its callers TEST —
#   never hands back a width it does not have. Returning 0 is the honest form
#   of such a helper; `return 8` is a guess.
#
# ★ THE FAILURE SHAPES A GUESSED WIDTH PRODUCES:
#   * INTERVAL_MONTH_DAY_NANO / DECIMAL256 — silent truncation to 8 bytes on
#     copy_column / gather / join.
#   * LARGE_STRING / LARGE_BINARY — the data buffer sized as num_rows * 8,
#     and the resulting column has NO offsets.
#   * DATE32 / TIME32_S / TIME32_MS / INTERVAL_YEAR_MONTH (int32-backed) —
#     `gather_batch` over a DATE32 column returns the wrong days, and a copy
#     with a non-zero `_offset` returns the wrong rows (`src_offset =
#     _offset * elem_size` doubled). No error, no signal.
#
# WHY THE REST RAISE INSTEAD OF RETURNING SOMETHING. Callers use this for
# `num_rows * width` byte arithmetic. For BOOL (bit-packed, `(n+7)>>3` bytes),
# STRING / BINARY / LARGE_* (extent lives in an offsets buffer),
# FIXED_SIZE_BINARY (width is schema metadata, not part of the type),
# DICTIONARY (codes + a shared dictionary), the nested layouts (child columns)
# and the *_VIEW layouts (variadic data buffers), that arithmetic is not
# merely imprecise — it is the wrong SHAPE. No return value makes those
# callers correct, so this returns none of them and names the type instead.


def arrow_fixed_byte_width(arrow_type: ArrowType) raises -> Int:
    """Return the byte width of a FIXED-BYTE-WIDTH ArrowType.

    Args:
        arrow_type: The ArrowType to measure.

    Returns:
        Bytes per element, for types that have a fixed per-element byte width.

    Raises:
        Error naming `arrow_type` if it has NO fixed byte width. The caller is
        doing `n * width` byte arithmetic on a layout that has no `width`; the
        fix belongs at the call site, not here.
    """
    # ---- 1-byte ----
    if arrow_type == ArrowType.INT8 or arrow_type == ArrowType.UINT8:
        return 1
    # ---- 2-byte ----
    elif (
        arrow_type == ArrowType.INT16
        or arrow_type == ArrowType.UINT16
        or arrow_type == ArrowType.FLOAT16
    ):
        return 2
    # ---- 4-byte ----
    elif (
        arrow_type == ArrowType.INT32
        or arrow_type == ArrowType.UINT32
        or arrow_type == ArrowType.FLOAT32
        # int32-BACKED temporals. An `else: return 8` fallback would size them
        # at DOUBLE their true width.
        or arrow_type == ArrowType.DATE32
        or arrow_type == ArrowType.TIME32_S
        or arrow_type == ArrowType.TIME32_MS
        or arrow_type == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return 4
    # ---- 8-byte ----
    elif (
        arrow_type == ArrowType.INT64
        or arrow_type == ArrowType.UINT64
        or arrow_type == ArrowType.FLOAT64
        # int64-BACKED temporals, enumerated so they are correct BY
        # STATEMENT (there is no fallback). Dropping any of them turns a
        # working path into a raise.
        or arrow_type == ArrowType.DATE64
        or arrow_type == ArrowType.TIMESTAMP
        or arrow_type == ArrowType.TIMESTAMP_S
        or arrow_type == ArrowType.TIMESTAMP_MS
        or arrow_type == ArrowType.TIMESTAMP_US
        or arrow_type == ArrowType.TIMESTAMP_NS
        or arrow_type == ArrowType.TIME64_US
        or arrow_type == ArrowType.TIME64_NS
        or arrow_type == ArrowType.DURATION_S
        or arrow_type == ArrowType.DURATION_MS
        or arrow_type == ArrowType.DURATION_US
        or arrow_type == ArrowType.DURATION_NS
        or arrow_type == ArrowType.INTERVAL_DAY_TIME
    ):
        return 8
    # ---- 16-byte ----
    # INTERVAL_MONTH_DAY_NANO is a packed (int32 months + int32 days + int64
    # nanos) slab.
    elif (
        arrow_type == ArrowType.DECIMAL128
        or arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO
    ):
        return 16
    # ---- 32-byte ----
    elif arrow_type == ArrowType.DECIMAL256:
        return 32
    # ---- NO FIXED BYTE WIDTH: say so, name the type, do not guess ----
    raise Error(
        "arrow_fixed_byte_width: ArrowType "
        + String(arrow_type)
        + " (type_id="
        + String(Int(arrow_type.type_id))
        + ") has NO fixed per-element byte width, so the caller's"
        " `num_rows * width` byte arithmetic is not merely imprecise for it —"
        " it is the wrong shape of arithmetic. BOOL is bit-packed ((n+7)>>3"
        " bytes); STRING / BINARY / LARGE_STRING / LARGE_BINARY carry their"
        " extent in an offsets buffer; FIXED_SIZE_BINARY's width is schema"
        " metadata, not part of the type; DICTIONARY carries codes + a shared"
        " dictionary; LIST / LARGE_LIST / STRUCT / MAP / UNION_* /"
        " FIXED_SIZE_LIST own child columns; the *_VIEW layouts own variadic"
        " data buffers; NULL has no data buffer and ERROR is not a storage"
        " type. Handle this layout explicitly at the call site (see the varlen"
        " / dictionary / nested / BOOL arms of `compiler_helpers._copy_column`"
        " for the shape), or route the column through a path that does. A"
        " guessed `return 8` here silently mis-sizes INTERVAL_MONTH_DAY_NANO,"
        " DECIMAL256, LARGE_STRING, and DATE32/TIME32_*/INTERVAL_YEAR_MONTH."
    )
