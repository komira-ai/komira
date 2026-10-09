# =============================================================================
# composite_key.mojo — runtime composite-key values, hash and equality
# =============================================================================
#
# The key value, hash and equality a multi-column GROUP BY table uses
# (`komira_op_agg_state.composite_hash_table` through the `KeyHashFnv1..4` /
# `KeyEqElementwise1..4` conformers in `agg_state_slab.mojo`). This module ships:
#   - `ColumnValue`, a tagged union holding one Int64 / Float64 / String /
#     Bool component.
#   - `KeyValue1..4`, fixed-arity tuples of `ColumnValue`.
#   - `hash_key_value1..4`, an FNV-1a 64-bit hash over the components.
#   - `eq_key_value1..4`, component-wise equality.
#
# No key extractor (no per-arity adapter over the ExprX traits) is declared
# here; the caller builds the `KeyValueN` itself.
#
# Hash and equality are one contract: `eq(a, b)` implies `hash(a) == hash(b)`.
# Float64 components follow the GROUP BY model of
# `komira_udf.float_quotient_order`: `+0.0` and `-0.0` are one key, every NaN
# is one key. Equality uses `float_quotient_eq_f64`; the hash folds
# `canonical_bits_f64`, the bit pattern of the canonical representative.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - `KeyValueN` is a fixed-arity struct (no List). The String component
#     holds a heap String; the other components are inline scalars.
# =============================================================================

from komira_udf.float_quotient_order import (
    canonical_bits_f64,
    float_quotient_eq_f64,
)


# =============================================================================
# §1 — ColumnValue — runtime tagged-union for one composite-key component
# =============================================================================
#
# A composite key's hash + equality needs to compare components position-
# wise across rows. Since each component can be a different DType (Int64
# / Float64 / String / Bool), the runtime KeyValueN holds N tagged
# ColumnValue cells.
#
# ColumnValue uses a tag plus one Optional per arm. The tag identifies
# which cell is populated; the other cells are None.
#
# The CVT_* tag values are local to this module; they are not the
# `komira_arrow.ArrowType` codes and nothing converts between the two.
# =============================================================================

comptime CVT_INT64: UInt8 = 8
comptime CVT_FLOAT64: UInt8 = 12
comptime CVT_STRING: UInt8 = 14
comptime CVT_BOOL: UInt8 = 3


struct ColumnValue(Copyable, Movable, Deinitable):
    """Tagged-union runtime cell for one composite-key component.

    Holds exactly one of {Int64, Float64, String, Bool} per the
    `tag` field. The other Optional cells are None.

    Used as a field of KeyValueN (the N-tuple runtime key value).
    """

    var tag: UInt8
    var _i64: Optional[Int64]
    var _f64: Optional[Float64]
    var _str: Optional[String]
    var _b: Optional[Bool]

    def __init__(out self, value: Int64):
        """Construct from an Int64 value."""
        self.tag = CVT_INT64
        self._i64 = Optional(value)
        self._f64 = None
        self._str = None
        self._b = None

    def __init__(out self, value: Float64):
        """Construct from a Float64 value."""
        self.tag = CVT_FLOAT64
        self._i64 = None
        self._f64 = Optional(value)
        self._str = None
        self._b = None

    def __init__(out self, var value: String):
        """Construct from a String value (consumed by move)."""
        self.tag = CVT_STRING
        self._i64 = None
        self._f64 = None
        self._str = Optional(value^)
        self._b = None

    def __init__(out self, value: Bool):
        """Construct from a Bool value."""
        self.tag = CVT_BOOL
        self._i64 = None
        self._f64 = None
        self._str = None
        self._b = Optional(value)

    @always_inline
    def kind(self) -> UInt8:
        """Return the value's DType tag."""
        return self.tag

    @always_inline
    def as_i64(self) -> Int64:
        """Read the Int64 payload. Caller must verify `kind() == CVT_INT64`.

        Returns 0 if the active arm is not Int64 (safety fallback;
        production usage always pre-checks the tag)."""
        if self._i64:
            return self._i64.value()
        return Int64(0)

    @always_inline
    def as_f64(self) -> Float64:
        """Read the Float64 payload. See as_i64 for fallback semantics."""
        if self._f64:
            return self._f64.value()
        return Float64(0.0)

    @always_inline
    def as_str(self) -> String:
        """Read the String payload (returns a copy). See as_i64 for
        fallback semantics."""
        if self._str:
            return self._str.value()
        return String("")

    @always_inline
    def as_bool(self) -> Bool:
        """Read the Bool payload. See as_i64 for fallback semantics."""
        if self._b:
            return self._b.value()
        return False


# =============================================================================
# §2 — KeyValue1..4 — runtime N-tuple value structs
# =============================================================================


@fieldwise_init
struct KeyValue1(Copyable, Movable, Deinitable):
    """Runtime 1-component composite key value."""

    var c0: ColumnValue


@fieldwise_init
struct KeyValue2(Copyable, Movable, Deinitable):
    """Runtime 2-component composite key value. Mirrors the
    KeyValue(String, Int64) shape but generalized via ColumnValue."""

    var c0: ColumnValue
    var c1: ColumnValue


@fieldwise_init
struct KeyValue3(Copyable, Movable, Deinitable):
    """Runtime 3-component composite key value."""

    var c0: ColumnValue
    var c1: ColumnValue
    var c2: ColumnValue


@fieldwise_init
struct KeyValue4(Copyable, Movable, Deinitable):
    """Runtime 4-component composite key value."""

    var c0: ColumnValue
    var c1: ColumnValue
    var c2: ColumnValue
    var c3: ColumnValue


# =============================================================================
# §3 — Generic helpers for hashing + equality over KeyValueN
# =============================================================================
#
# These helpers operate on the runtime KeyValueN structs and provide:
#   - `hash_key_valueN` — FNV-1a 64-bit hash over the ColumnValue components.
#   - `eq_key_valueN` — component-wise equality.
#
# The FNV-1a polynomial is 0x100000001b3
# (1099511628211 decimal); FNV offset is 14695981039346656037.
# =============================================================================


comptime FNV_OFFSET: UInt64 = 14695981039346656037
comptime FNV_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv1a_step(state: UInt64, byte: UInt8) -> UInt64:
    """One FNV-1a 64-bit step. `state ^= byte; state *= prime`."""
    return (state ^ UInt64(byte)) * FNV_PRIME


@always_inline
def _hash_column_value(state: UInt64, cv: ColumnValue) -> UInt64:
    """Fold a single ColumnValue into a running FNV-1a state.

    Per-DType:
      - Int64: hash the 8 bytes of the Int64 (little-endian byte order).
      - Float64: hash the 8 little-endian bytes of `canonical_bits_f64`,
        the IEEE-754 bit pattern after -0.0 -> +0.0 and every NaN -> the
        canonical NaN, so the values `_eq_column_value` calls equal hash
        equal.
      - String: hash each byte of the UTF-8 representation.
      - Bool: hash 1 byte (0x00 or 0x01).
      - Any other tag: fold nothing.
    The tag itself is not hashed; `_eq_column_value` separates the kinds.
    """
    var s = state
    var t = cv.kind()
    if t == CVT_INT64:
        var v = UInt64(cv.as_i64())
        for k in range(8):
            var b = UInt8((v >> UInt64((k * 8))) & 0xFF)
            s = _fnv1a_step(s, b)
    elif t == CVT_FLOAT64:
        var v = canonical_bits_f64(cv.as_f64())
        for k in range(8):
            var b = UInt8((v >> UInt64((k * 8))) & 0xFF)
            s = _fnv1a_step(s, b)
    elif t == CVT_STRING:
        var sv = cv.as_str()
        var sb = sv.as_bytes()
        for j in range(len(sb)):
            s = _fnv1a_step(s, sb[j])
    elif t == CVT_BOOL:
        var b: UInt8 = 1 if cv.as_bool() else 0
        s = _fnv1a_step(s, b)
    return s


@always_inline
def hash_key_value1(k: KeyValue1) -> UInt64:
    """FNV-1a 64-bit hash over a 1-component KeyValue."""
    var s = FNV_OFFSET
    s = _hash_column_value(s, k.c0)
    return s


@always_inline
def hash_key_value2(k: KeyValue2) -> UInt64:
    """FNV-1a 64-bit hash over a 2-component KeyValue."""
    var s = FNV_OFFSET
    s = _hash_column_value(s, k.c0)
    s = _hash_column_value(s, k.c1)
    return s


@always_inline
def hash_key_value3(k: KeyValue3) -> UInt64:
    """FNV-1a 64-bit hash over a 3-component KeyValue."""
    var s = FNV_OFFSET
    s = _hash_column_value(s, k.c0)
    s = _hash_column_value(s, k.c1)
    s = _hash_column_value(s, k.c2)
    return s


@always_inline
def hash_key_value4(k: KeyValue4) -> UInt64:
    """FNV-1a 64-bit hash over a 4-component KeyValue."""
    var s = FNV_OFFSET
    s = _hash_column_value(s, k.c0)
    s = _hash_column_value(s, k.c1)
    s = _hash_column_value(s, k.c2)
    s = _hash_column_value(s, k.c3)
    return s


@always_inline
def _eq_column_value(a: ColumnValue, b: ColumnValue) -> Bool:
    """Component equality on two ColumnValue cells. Returns False on a tag
    mismatch and on a tag outside the four arms.

    Float64 uses `float_quotient_eq_f64`, not IEEE `==`: +0.0 equals
    -0.0 (as in IEEE) and every NaN equals every NaN (unlike IEEE), so all
    NaN rows form one group, matching the canonical-bits hash.
    """
    if a.kind() != b.kind():
        return False
    var t = a.kind()
    if t == CVT_INT64:
        return a.as_i64() == b.as_i64()
    elif t == CVT_FLOAT64:
        return float_quotient_eq_f64(a.as_f64(), b.as_f64())
    elif t == CVT_STRING:
        return a.as_str() == b.as_str()
    elif t == CVT_BOOL:
        return a.as_bool() == b.as_bool()
    return False


@always_inline
def eq_key_value1(a: KeyValue1, b: KeyValue1) -> Bool:
    """Element-wise equality on two 1-component KeyValues."""
    return _eq_column_value(a.c0, b.c0)


@always_inline
def eq_key_value2(a: KeyValue2, b: KeyValue2) -> Bool:
    """Element-wise equality on two 2-component KeyValues."""
    if not _eq_column_value(a.c0, b.c0):
        return False
    return _eq_column_value(a.c1, b.c1)


@always_inline
def eq_key_value3(a: KeyValue3, b: KeyValue3) -> Bool:
    """Element-wise equality on two 3-component KeyValues."""
    if not _eq_column_value(a.c0, b.c0):
        return False
    if not _eq_column_value(a.c1, b.c1):
        return False
    return _eq_column_value(a.c2, b.c2)


@always_inline
def eq_key_value4(a: KeyValue4, b: KeyValue4) -> Bool:
    """Element-wise equality on two 4-component KeyValues."""
    if not _eq_column_value(a.c0, b.c0):
        return False
    if not _eq_column_value(a.c1, b.c1):
        return False
    if not _eq_column_value(a.c2, b.c2):
        return False
    return _eq_column_value(a.c3, b.c3)
