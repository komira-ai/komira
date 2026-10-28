# =============================================================================
# ScalarValue — type-erased scalar for Expr literals
# =============================================================================
#
# A tagged union holding literal values for use in expression trees.
# Kept minimal -- no 40-variant explosion like DataFusion.
#
# Each ScalarValue stores its DType tag plus one populated value field.
# Only the field matching the dtype is meaningful.
#
# Out-of-band kinds beyond the DType-keyed ones include:
#   - DECIMAL128 (precision/scale carried in field metadata; high+low Int64)
#   - DATE32     (days since unix epoch)
#   - TIMESTAMP  (micros since unix epoch — Arrow Timestamp[us] canonical)
#
# Discriminator strategy: the existing DType-tag is preserved for the
# scalar kinds Mojo's DType can represent (int32/64, float32/64, bool,
# null sentinel). For the other kinds, an out-of-band `_kind: UInt8`
# sub-tag is set to a SCALAR_KIND_* constant; `_kind == SCALAR_KIND_DTYPE`
# (the default, 0) means "use dtype", so the factories and the 0-arg
# default need no kind argument.
# =============================================================================


from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.render_text import write_hex, write_quoted

# Sub-tag for kinds that don't have a clean DType representative.
comptime SCALAR_KIND_DTYPE: UInt8 = 0        # default — use the `dtype` field
comptime SCALAR_KIND_DECIMAL128: UInt8 = 1
comptime SCALAR_KIND_DATE32: UInt8 = 2
comptime SCALAR_KIND_TIMESTAMP: UInt8 = 3
# EMPTY-STRING ≢ NULL.  Strings carry an out-of-band
# `_kind == SCALAR_KIND_STRING` discriminant rather than a
# "dtype == DTYPE_NONE && len(string_val) > 0" convention, which would make
# `''` (empty string) indistinguishable from a NULL (both dtype==invalid with
# an empty string) — a wrong-answer footgun (SQL: `'' <> NULL`). With the
# dedicated kind, the string's `_kind` alone discriminates it, so an empty
# string is a first-class value and a NULL stays a NULL.
comptime SCALAR_KIND_STRING: UInt8 = 4
# Additional value-model kinds for SQL money/date math. Each is out-of-band
# (`_kind`) because Mojo's DType cannot represent it. int8/16 and
# uint8/16/32/64 stay DType-keyed (DType HAS those), carried in int_val.
comptime SCALAR_KIND_INTERVAL: UInt8 = 5    # month-day-nano interval
comptime SCALAR_KIND_TIME: UInt8 = 6        # time-of-day (int_val + time_unit)
comptime SCALAR_KIND_DURATION: UInt8 = 7    # duration (int_val + time_unit)
comptime SCALAR_KIND_DECIMAL256: UInt8 = 8  # 256-bit decimal (4 Int64 limbs)
comptime SCALAR_KIND_BINARY: UInt8 = 9      # opaque bytes (in string_val)

# Arrow time unit for TIME / DURATION scalars.
comptime SCALAR_TIME_UNIT_SECOND: UInt8 = 0
comptime SCALAR_TIME_UNIT_MILLI: UInt8 = 1
comptime SCALAR_TIME_UNIT_MICRO: UInt8 = 2
comptime SCALAR_TIME_UNIT_NANO: UInt8 = 3


struct ScalarValue(Movable, Copyable, Writable):
    """A type-erased scalar value for use in Expr literals.

    Stores a DType tag and one value field per supported type.
    Only the field matching the dtype is meaningful.

    Extended with a `_kind` sub-tag + decimal128/date32/timestamp (and
    further) storage fields. The DType-keyed kinds (int/float/bool/null)
    keep `_kind == SCALAR_KIND_DTYPE`.
    """

    var dtype: DType
    var int_val: Int64
    var float_val: Float64
    var string_val: String
    var bool_val: Bool
    # Out-of-band kind discriminator for non-DType variants.
    var _kind: UInt8
    # DECIMAL128 storage. The 128-bit integer payload (high+low) plus
    # the precision/scale — (p,s) ride on the scalar
    # so a `WHERE price > 100.50::DECIMAL(10,2)` literal round-trips with
    # enough information to do scale alignment without consulting a schema.
    var dec128_high: Int64
    var dec128_low: Int64
    var dec128_precision: Int
    var dec128_scale: Int
    # DATE32 storage (days since unix epoch).
    var date32_val: Int32
    # TIMESTAMP storage (microseconds since unix epoch; Arrow
    # Timestamp[us] canonical resolution).
    var ts_micros: Int64
    # The preserved logical
    # type of a typed NULL. `null(dtype)` stores `dtype` HERE and sets the
    # discriminant `dtype` field to `DTYPE_NONE`, so `is_null()` is True
    # for EVERY typed null. Setting `dtype=int64` instead would make
    # `null(int64)` read as int 0 (`is_int()` True, `is_null()` False) — a
    # wrong-answer footgun (e.g. `x = (SELECT max(y) FROM empty)` would match
    # x=0 rows). Consumers that need a null's declared type (schema inference
    # of a null literal) read `null_type()`; the null discriminant stays
    # `_kind == SCALAR_KIND_DTYPE and dtype == DTYPE_NONE and string empty`.
    var null_dtype: DType
    # Extended-kind storage. Each field is meaningful
    # only for its owning `_kind`; all others zero-init.
    #   INTERVAL (SCALAR_KIND_INTERVAL): month-day-nano triple.
    var iv_months: Int32
    var iv_days: Int32
    var iv_nanos: Int64
    #   TIME (SCALAR_KIND_TIME) + DURATION (SCALAR_KIND_DURATION): the scalar
    #   value lives in `int_val`; `time_unit` is the Arrow unit (s/ms/us/ns).
    var time_unit: UInt8
    #   DECIMAL256 (SCALAR_KIND_DECIMAL256): 256-bit two's-complement value as
    #   two 128-bit halves. The LOW 128 bits reuse `dec128_low`/`dec128_high`;
    #   the HIGH 128 bits live here. Precision/scale reuse `dec128_precision`/
    #   `dec128_scale`. BINARY reuses `string_val` for the raw bytes; the
    #   narrow int / uint literals reuse `int_val` (DType-keyed).
    var dec256_high_lo: Int64
    var dec256_high_hi: Int64

    # --- Constructors ---

    def __init__(out self):
        """Default constructor -- null value."""
        self.dtype = DTYPE_NONE
        self.int_val = 0
        self.float_val = 0.0
        self.string_val = String("")
        self.bool_val = False
        self._kind = SCALAR_KIND_DTYPE
        self.dec128_high = 0
        self.dec128_low = 0
        self.dec128_precision = 0
        self.dec128_scale = 0
        self.date32_val = Int32(0)
        self.ts_micros = 0
        self.null_dtype = DTYPE_NONE
        self.iv_months = Int32(0)
        self.iv_days = Int32(0)
        self.iv_nanos = 0
        self.time_unit = SCALAR_TIME_UNIT_MICRO
        self.dec256_high_lo = 0
        self.dec256_high_hi = 0

    def __init__(out self, dtype: DType, int_val: Int64, float_val: Float64, string_val: String, bool_val: Bool):
        """5-arg ctor used by the factory methods
        (int/float/bool/string/null). The extended-kind fields zero-init."""
        self.dtype = dtype
        self.int_val = int_val
        self.float_val = float_val
        self.string_val = string_val
        self.bool_val = bool_val
        self._kind = SCALAR_KIND_DTYPE
        self.dec128_high = 0
        self.dec128_low = 0
        self.dec128_precision = 0
        self.dec128_scale = 0
        self.date32_val = Int32(0)
        self.ts_micros = 0
        self.null_dtype = DTYPE_NONE
        self.iv_months = Int32(0)
        self.iv_days = Int32(0)
        self.iv_nanos = 0
        self.time_unit = SCALAR_TIME_UNIT_MICRO
        self.dec256_high_lo = 0
        self.dec256_high_hi = 0

    def copy(self) -> Self:
        """Explicit copy."""
        var sv = Self(self.dtype, self.int_val, self.float_val, self.string_val.copy(), self.bool_val)
        sv._kind = self._kind
        sv.dec128_high = self.dec128_high
        sv.dec128_low = self.dec128_low
        sv.dec128_precision = self.dec128_precision
        sv.dec128_scale = self.dec128_scale
        sv.date32_val = self.date32_val
        sv.ts_micros = self.ts_micros
        sv.null_dtype = self.null_dtype
        sv.iv_months = self.iv_months
        sv.iv_days = self.iv_days
        sv.iv_nanos = self.iv_nanos
        sv.time_unit = self.time_unit
        sv.dec256_high_lo = self.dec256_high_lo
        sv.dec256_high_hi = self.dec256_high_hi
        return sv^

    # --- Factory methods ---

    @staticmethod
    @always_inline
    def from_int(v: Int) -> ScalarValue:
        """Create a ScalarValue holding an Int64."""
        return ScalarValue(DType.int64, Int64(v), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_int64(v: Int64) -> ScalarValue:
        """Create a ScalarValue holding an Int64."""
        return ScalarValue(DType.int64, v, 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_int32(v: Int32) -> ScalarValue:
        """Create a ScalarValue holding an Int32."""
        return ScalarValue(DType.int32, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_float(v: Float64) -> ScalarValue:
        """Create a ScalarValue holding a Float64."""
        return ScalarValue(DType.float64, 0, v, String(""), False)

    @staticmethod
    @always_inline
    def from_float32(v: Float32) -> ScalarValue:
        """Create a ScalarValue holding a Float32."""
        return ScalarValue(DType.float32, 0, Float64(v), String(""), False)

    @staticmethod
    @always_inline
    def from_string(v: String) -> ScalarValue:
        """Create a ScalarValue holding a String (Utf8).

        The string is discriminated by the
        out-of-band `_kind == SCALAR_KIND_STRING` sub-tag, NOT by a
        `dtype == DTYPE_NONE && non-empty` convention.  This makes `''`
        (empty string) a first-class value distinct from a NULL — see
        `SCALAR_KIND_STRING` above.  `dtype` stays `DTYPE_NONE` (there is
        no Mojo DType for Utf8); consumers must use `is_string()` /
        `string_val`, never the dtype sentinel.
        """
        var sv = ScalarValue(DTYPE_NONE, 0, 0.0, v, False)
        sv._kind = SCALAR_KIND_STRING
        return sv^

    @staticmethod
    @always_inline
    def from_bool(v: Bool) -> ScalarValue:
        """Create a ScalarValue holding a Bool."""
        return ScalarValue(DType.bool, 0, 0.0, String(""), v)

    @staticmethod
    @always_inline
    def null(dtype: DType) -> ScalarValue:
        """Create a typed NULL ScalarValue.

        The null
        discriminant is `dtype == DTYPE_NONE`, so this sets the `dtype`
        field to `DTYPE_NONE` (making `is_null()` True for EVERY dtype)
        and stashes the intended logical type in `null_dtype` (read back via
        `null_type()`). Setting `dtype = dtype` would, for any
        non-invalid `dtype`, produce a value discriminated as its
        base kind (e.g. `null(int64)` would look like int 0), silently violating
        this constructor's own "typed NULL" contract.
        """
        var sv = ScalarValue()
        sv.dtype = DTYPE_NONE
        sv.null_dtype = dtype
        return sv^

    # --- Decimal / date / timestamp factory methods ---

    @staticmethod
    def decimal128(high: Int64, low: Int64, precision: Int = 0, scale: Int = 0) -> ScalarValue:
        """Create a Decimal128 ScalarValue carrying the 128-bit payload
        (high+low) and the precision/scale.

        `(precision, scale)` are
        carried on the scalar itself (in addition to being on any Field) so
        a decimal literal in a predicate can be scale-aligned without a
        schema lookup.  The 2-arg form (precision/scale = 0) remains for
        callers that don't yet have (p,s) — those must populate it before
        use in arithmetic/compare.
        """
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_DECIMAL128
        sv.dec128_high = high
        sv.dec128_low = low
        sv.dec128_precision = precision
        sv.dec128_scale = scale
        return sv^

    @staticmethod
    def decimal128_i128(value: SIMD[DType.int128, 1], precision: Int, scale: Int) -> ScalarValue:
        """Create a Decimal128 ScalarValue from a native int128 + (p,s)."""
        var hi = (value >> SIMD[DType.int128, 1](64)).cast[DType.int64]()
        var lo = value.cast[DType.int64]()
        return ScalarValue.decimal128(hi, lo, precision, scale)

    @always_inline
    def decimal_value_i128(self) -> SIMD[DType.int128, 1]:
        """The 128-bit unscaled value (only meaningful when is_decimal128())."""
        # ⛔ NOT `low.cast[uint64]().cast[uint128]().cast[int128]()`. MEASURED
        # on this toolchain: for low = -1 that CHAIN answered -1 -- the int64 ->
        # uint64 -> uint128 pair folds into one sign-extension -- so every
        # decimal literal whose low word
        # has its top bit set (|value| >= 2^63 with a zero high word, e.g.
        # CAST('18446744073709551615' AS DECIMAL(20,0))) read back as a
        # negative number. ⚠ SCOPE: a UInt64 LOADED from memory (a List / a
        # column) and then cast to uint128 ZERO-extends (measured with a runtime
        # probe) -- the uint64 -> uint128 casts over loaded
        # values elsewhere are correct; do not "fix" them. Unsigned-ness is
        # restored arithmetically here instead: a negative low word is its value
        # MINUS 2^64, so add 2^64 back.
        var hi128 = SIMD[DType.int128, 1](Int(self.dec128_high)) << SIMD[DType.int128, 1](64)
        var lo128 = SIMD[DType.int128, 1](Int(self.dec128_low))
        if self.dec128_low < 0:
            lo128 = lo128 + (SIMD[DType.int128, 1](1) << SIMD[DType.int128, 1](64))
        return hi128 + lo128

    @staticmethod
    def date32(days_since_epoch: Int32) -> ScalarValue:
        """Create a Date32 ScalarValue (days since unix epoch)."""
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_DATE32
        sv.date32_val = days_since_epoch
        return sv^

    @staticmethod
    def timestamp_micros(micros: Int64) -> ScalarValue:
        """Create a Timestamp ScalarValue (microseconds since unix epoch).

        Arrow Timestamp[us] canonical resolution. Other resolutions
        (ms / ns / s) should be converted to micros at construction.
        """
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_TIMESTAMP
        sv.ts_micros = micros
        return sv^

    # --- Extended-kind factory methods ---
    # Narrow / unsigned integers stay DType-keyed (Mojo DType has them); the
    # value lives in `int_val` (uint64 as its two's-complement bit pattern).

    @staticmethod
    @always_inline
    def from_int8(v: Int8) -> ScalarValue:
        """Create a ScalarValue holding an Int8 (DType-keyed, value in int_val)."""
        return ScalarValue(DType.int8, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_int16(v: Int16) -> ScalarValue:
        """Create a ScalarValue holding an Int16."""
        return ScalarValue(DType.int16, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_uint8(v: UInt8) -> ScalarValue:
        """Create a ScalarValue holding a UInt8."""
        return ScalarValue(DType.uint8, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_uint16(v: UInt16) -> ScalarValue:
        """Create a ScalarValue holding a UInt16."""
        return ScalarValue(DType.uint16, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_uint32(v: UInt32) -> ScalarValue:
        """Create a ScalarValue holding a UInt32."""
        return ScalarValue(DType.uint32, Int64(Int(v)), 0.0, String(""), False)

    @staticmethod
    @always_inline
    def from_uint64(v: UInt64) -> ScalarValue:
        """Create a ScalarValue holding a UInt64.

        The unsigned 64-bit value is stored as its two's-complement bit
        pattern in `int_val`; read it back with `uint64_value()` (a plain
        `int_val` read reinterprets values >= 2**63 as negative).
        """
        return ScalarValue(DType.uint64, v.cast[DType.int64](), 0.0, String(""), False)

    @always_inline
    def uint64_value(self) -> UInt64:
        """The unsigned 64-bit value (only meaningful when dtype==uint64)."""
        return self.int_val.cast[DType.uint64]()

    @staticmethod
    def interval_month_day_nano(months: Int32, days: Int32, nanos: Int64) -> ScalarValue:
        """Create an INTERVAL ScalarValue (Arrow MonthDayNano triple).

        Covers SQL `INTERVAL '1' MONTH` / `INTERVAL '1 day 06:00'` at the
        literal level — the three components stay independent (a month is not
        a fixed number of days, a day is not a fixed number of nanos).
        """
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_INTERVAL
        sv.iv_months = months
        sv.iv_days = days
        sv.iv_nanos = nanos
        return sv^

    @staticmethod
    def time_of_day(value: Int64, unit: UInt8 = SCALAR_TIME_UNIT_MICRO) -> ScalarValue:
        """Create a TIME (time-of-day) ScalarValue: `value` units since
        midnight. `unit` is an Arrow time unit (default micros)."""
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_TIME
        sv.int_val = value
        sv.time_unit = unit
        return sv^

    @staticmethod
    def duration(value: Int64, unit: UInt8 = SCALAR_TIME_UNIT_MICRO) -> ScalarValue:
        """Create a DURATION ScalarValue: `value` in `unit` (Arrow time unit).

        SQL `INTERVAL` with an exact time span. Distinct
        from INTERVAL (which keeps months/days independent of nanos)."""
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_DURATION
        sv.int_val = value
        sv.time_unit = unit
        return sv^

    @staticmethod
    def decimal256(
        low_low: Int64,
        low_high: Int64,
        high_low: Int64,
        high_high: Int64,
        precision: Int = 0,
        scale: Int = 0,
    ) -> ScalarValue:
        """Create a Decimal256 ScalarValue from four 64-bit limbs (little-end
        first: bits [0,64)=low_low, [64,128)=low_high, [128,192)=high_low,
        [192,256)=high_high) plus precision/scale.

        The low 128 bits reuse the decimal128 limbs; the high 128 bits use the
        dec256_* fields. For a literal we only need to carry + compare the
        bits, so no int256 arithmetic type is required.
        """
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_DECIMAL256
        sv.dec128_low = low_low
        sv.dec128_high = low_high
        sv.dec256_high_lo = high_low
        sv.dec256_high_hi = high_high
        sv.dec128_precision = precision
        sv.dec128_scale = scale
        return sv^

    @staticmethod
    def from_binary(var data: String) -> ScalarValue:
        """Create a BINARY (opaque bytes) ScalarValue. The bytes are carried
        in `string_val`; discriminated by `is_binary()` (NOT `is_string()`),
        so binary never collides with a Utf8 string literal."""
        var sv = ScalarValue()
        sv._kind = SCALAR_KIND_BINARY
        sv.string_val = data^
        return sv^

    # --- Type checks ---

    @always_inline
    def is_int(self) -> Bool:
        """True if this holds an integer value."""
        return self._kind == SCALAR_KIND_DTYPE and (self.dtype == DType.int64 or self.dtype == DType.int32)

    @always_inline
    def is_float(self) -> Bool:
        """True if this holds a float value."""
        return self._kind == SCALAR_KIND_DTYPE and (self.dtype == DType.float64 or self.dtype == DType.float32)

    @always_inline
    def is_string(self) -> Bool:
        """True if this holds a string value (including the empty string).

        Discriminated by the dedicated
        `_kind == SCALAR_KIND_STRING` sub-tag — NOT a
        "dtype == DTYPE_NONE && len > 0" convention, which would exclude the
        empty string and conflate it with NULL.  `from_string("")` is a
        real (non-null) string value.
        """
        return self._kind == SCALAR_KIND_STRING

    @always_inline
    def is_bool(self) -> Bool:
        """True if this holds a boolean value."""
        return self._kind == SCALAR_KIND_DTYPE and self.dtype == DType.bool

    @always_inline
    def is_null(self) -> Bool:
        """True if this is a NULL (typed or untyped).

        True for EVERY
        `null(dtype)` because `null()` sets `dtype == DTYPE_NONE`
        regardless of the requested logical type (that type lives in
        `null_dtype`; read it via `null_type()`).

        The empty string is NOT a NULL.  Strings
        (including `''`) carry `_kind == SCALAR_KIND_STRING`, so the NULL
        discriminant is exactly `_kind == SCALAR_KIND_DTYPE && dtype ==
        DTYPE_NONE`.  The trailing empty-string check is redundant given the
        kind gate and is kept as a defensive guard.
        """
        return self._kind == SCALAR_KIND_DTYPE and self.dtype == DTYPE_NONE and self.string_val.byte_length() == 0

    @always_inline
    def null_type(self) -> DType:
        """The preserved logical type of a typed NULL.

        Only meaningful when `is_null()` is True. Returns the `dtype`
        passed to `ScalarValue.null(dtype)` (e.g. `DType.int64`), or
        `DTYPE_NONE` for an untyped/default null. Consumers that need a
        null literal's declared type (schema inference of a null-literal
        projection) read this instead of `dtype` (which is always the
        `DTYPE_NONE` null discriminant).
        """
        return self.null_dtype

    @always_inline
    def is_decimal128(self) -> Bool:
        """True if this holds a Decimal128 value."""
        return self._kind == SCALAR_KIND_DECIMAL128

    @always_inline
    def is_date32(self) -> Bool:
        """True if this holds a Date32 value."""
        return self._kind == SCALAR_KIND_DATE32

    @always_inline
    def is_timestamp(self) -> Bool:
        """True if this holds a Timestamp[us] value."""
        return self._kind == SCALAR_KIND_TIMESTAMP

    # --- Extended-kind type checks ---

    @always_inline
    def is_signed_int_narrow(self) -> Bool:
        """True for an int8 / int16 literal (value in int_val, DType-keyed)."""
        return self._kind == SCALAR_KIND_DTYPE and (self.dtype == DType.int8 or self.dtype == DType.int16)

    @always_inline
    def is_uint(self) -> Bool:
        """True for any unsigned integer literal (uint8/16/32/64)."""
        return self._kind == SCALAR_KIND_DTYPE and (
            self.dtype == DType.uint8
            or self.dtype == DType.uint16
            or self.dtype == DType.uint32
            or self.dtype == DType.uint64
        )

    @always_inline
    def is_any_integer(self) -> Bool:
        """True for any integer literal (signed int8/16/32/64 or unsigned
        uint8/16/32/64). The value is always carried in `int_val` (uint64 as
        its two's-complement bit pattern). Used by the predicate-carry
        classification paths that fold all integers to the Int64 family."""
        return self.is_int() or self.is_signed_int_narrow() or self.is_uint()

    @always_inline
    def is_interval(self) -> Bool:
        """True if this holds an INTERVAL (month-day-nano) value."""
        return self._kind == SCALAR_KIND_INTERVAL

    @always_inline
    def is_time(self) -> Bool:
        """True if this holds a TIME (time-of-day) value."""
        return self._kind == SCALAR_KIND_TIME

    @always_inline
    def is_duration(self) -> Bool:
        """True if this holds a DURATION value."""
        return self._kind == SCALAR_KIND_DURATION

    @always_inline
    def is_decimal256(self) -> Bool:
        """True if this holds a Decimal256 value."""
        return self._kind == SCALAR_KIND_DECIMAL256

    @always_inline
    def is_binary(self) -> Bool:
        """True if this holds a BINARY (opaque bytes) value."""
        return self._kind == SCALAR_KIND_BINARY

    @always_inline
    def fits_int64_family(self) -> Bool:
        """True for an integer literal that folds LOSSLESSLY to the Int64
        runtime family: int8/16/32/64 and uint8/16/32 (all in [-2**63, 2**63)).

        The predicate-carry classification paths
        (`lower_untyped_expr`, `expr_to_runtime`) use this to carry the
        narrow/unsigned integer
        literals. uint64 is EXCLUDED — values >= 2**63 do not fit signed
        Int64, so it stays unsupported by the untyped I64-family carry rather
        than silently flipping sign."""
        if self.is_int() or self.is_signed_int_narrow():
            return True
        return self._kind == SCALAR_KIND_DTYPE and (
            self.dtype == DType.uint8
            or self.dtype == DType.uint16
            or self.dtype == DType.uint32
        )

    # --- Equality (needed for round-trip tests) ---

    def __eq__(self, other: ScalarValue) -> Bool:
        """Structural equality across all kinds."""
        if self._kind != other._kind:
            return False
        if self._kind == SCALAR_KIND_DECIMAL128:
            return (
                self.dec128_high == other.dec128_high
                and self.dec128_low == other.dec128_low
                and self.dec128_precision == other.dec128_precision
                and self.dec128_scale == other.dec128_scale
            )
        if self._kind == SCALAR_KIND_DATE32:
            return self.date32_val == other.date32_val
        if self._kind == SCALAR_KIND_TIMESTAMP:
            return self.ts_micros == other.ts_micros
        if self._kind == SCALAR_KIND_STRING:
            # Strings compare by text — `'' == ''` is
            # True, and a string never equals a NULL (kinds already differ,
            # caught by the `_kind != other._kind` early-return above).
            return self.string_val == other.string_val
        # The extended-kind arms.
        if self._kind == SCALAR_KIND_INTERVAL:
            return (
                self.iv_months == other.iv_months
                and self.iv_days == other.iv_days
                and self.iv_nanos == other.iv_nanos
            )
        if self._kind == SCALAR_KIND_TIME or self._kind == SCALAR_KIND_DURATION:
            # Same-kind (guaranteed by the early return); compare value + unit.
            return self.int_val == other.int_val and self.time_unit == other.time_unit
        if self._kind == SCALAR_KIND_DECIMAL256:
            return (
                self.dec128_low == other.dec128_low
                and self.dec128_high == other.dec128_high
                and self.dec256_high_lo == other.dec256_high_lo
                and self.dec256_high_hi == other.dec256_high_hi
                and self.dec128_precision == other.dec128_precision
                and self.dec128_scale == other.dec128_scale
            )
        if self._kind == SCALAR_KIND_BINARY:
            return self.string_val == other.string_val
        # SCALAR_KIND_DTYPE — discriminate by dtype.
        if self.dtype != other.dtype:
            return False
        if self.is_any_integer():
            # All integer widths (int8/16/32/64, uint8/16/32/64)
            # carry the value in int_val — dtype-equality above already
            # ensured both operands share the exact width.
            return self.int_val == other.int_val
        if self.is_float():
            return self.float_val == other.float_val
        if self.is_bool():
            return self.bool_val == other.bool_val
        if self.is_null():
            # Two nulls are
            # structurally equal iff their preserved logical type matches, so
            # `null(int64) != null(int32)` (and `null(int64) != from_int64(0)`),
            # even though the `dtype` field is always `invalid` for a null.
            return other.is_null() and self.null_dtype == other.null_dtype
        # Strings are SCALAR_KIND_STRING (handled
        # above), so a `_kind == DTYPE` value reaching here is neither
        # int/float/bool/null nor a string — no such variant exists today.
        # Compare the (empty) string_val defensively for structural equality.
        return self.string_val == other.string_val

    def __ne__(self, other: ScalarValue) -> Bool:
        return not (self == other)

    # --- Writable ---

    def write_to[W: Writer](self, mut writer: W):
        """Human-readable representation."""
        if self.is_decimal128():
            writer.write("ScalarValue(decimal128(", self.dec128_precision, ",", self.dec128_scale, "), hi=", Int(self.dec128_high), ", lo=", Int(self.dec128_low), ")")
        elif self.is_date32():
            writer.write("ScalarValue(date32, ", Int(self.date32_val), ")")
        elif self.is_timestamp():
            writer.write("ScalarValue(timestamp[us], ", Int(self.ts_micros), ")")
        elif self.is_interval():
            writer.write("ScalarValue(interval, months=", Int(self.iv_months), ", days=", Int(self.iv_days), ", nanos=", Int(self.iv_nanos), ")")
        elif self.is_time():
            writer.write("ScalarValue(time, ", Int(self.int_val), ", unit=", Int(self.time_unit), ")")
        elif self.is_duration():
            writer.write("ScalarValue(duration, ", Int(self.int_val), ", unit=", Int(self.time_unit), ")")
        elif self.is_decimal256():
            writer.write("ScalarValue(decimal256(", self.dec128_precision, ",", self.dec128_scale, "), hh=", Int(self.dec256_high_hi), ", hl=", Int(self.dec256_high_lo), ", lh=", Int(self.dec128_high), ", ll=", Int(self.dec128_low), ")")
        elif self.is_binary():
            # ⛔ PLAN IDENTITY: the BYTES, not only their count. This render
            # feeds `LogicalPlan.structural_hash`, the plan-compile cache key;
            # a length-only render let `b = X'0102'` and `b = X'0304'` share a
            # compiled plan (komira#960).
            writer.write("ScalarValue(binary, ", self.string_val.byte_length(), " bytes, ")
            write_hex(writer, self.string_val)
            writer.write(")")
        elif self.is_int():
            writer.write("ScalarValue(", self.dtype, ", ", Int(self.int_val), ")")
        elif self.is_signed_int_narrow() or self.is_uint():
            writer.write("ScalarValue(", self.dtype, ", ", Int(self.int_val), ")")
        elif self.is_float():
            writer.write("ScalarValue(", self.dtype, ", ", self.float_val, ")")
        elif self.is_string():
            # Escaped (`render_text`): a raw write lets the value close its
            # own quote and spell a different list (komira#960).
            writer.write("ScalarValue(utf8, ")
            write_quoted(writer, self.string_val)
            writer.write(")")
        elif self.is_bool():
            if self.bool_val:
                writer.write("ScalarValue(bool, true)")
            else:
                writer.write("ScalarValue(bool, false)")
        elif self.null_dtype == DTYPE_NONE:
            writer.write("ScalarValue(null)")
        else:
            # ⛔ PLAN IDENTITY: a typed NULL's declared type is its output
            # column's type, so `null(int64)` and `null(float64)` must not
            # render alike (komira#960). An untyped NULL renders as before.
            writer.write("ScalarValue(null, ", self.null_dtype, ")")
