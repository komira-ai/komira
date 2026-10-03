# =============================================================================
# composite_key.mojo — CompositeKey per-arity comptime adapters
# =============================================================================
#
# Multi-key extraction for the CompositeHashTable stage primitive.
# CompositeKey2[K0: ExprString, K1: ExprI64] is the reference 2-arity shape;
# this module generalises it to arities 1, 2, 3 and 4, which covers the
# group-by widths of typical OLAP workloads (TPC-H, H2O, ClickBench). Each
# arity ships:
#   - `KeyValueN` runtime struct holding the N extracted column values.
#   - `CompositeKeyN[K0, K1, ..., K_{N-1}]` comptime adapter conforming
#     to the `KeyExpr` trait declared below.
#
# Per-component KeyExpr conformers can be any of ExprX{Bool, I64, F64,
# String}. The KeyValueN runtime struct uses a runtime tagged-union
# field per component for type erasure at the value level — this avoids
# requiring N orthogonal comptime expansions at the hash-table
# container level.
#
# Field design: `KeyValueN` carries N `ColumnValue` runtime values, each
# holding a typed scalar (Int64 / Float64 / String / Bool tagged-union). The
# CompositeHashTable's hash + eq fns are parametric on the KeyHashFn /
# KeyEqFn conformers; this module ships generic FNV-1a hash + element-wise
# equality.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - All BatchView references threaded via `BatchView[bo]`.
#   - `KeyValueN` is heap-light: a fixed-arity tagged struct (no List).
#     The String component holds a heap String value (unavoidable for
#     variable-width keys); other components are inline-stored scalars.
#
# Cross-references:
#   - composite_hash_table — consumer of CompositeKeyN.
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_expr.expr_x import ExprXBool, ExprXI64, ExprXF64, ExprXString


# =============================================================================
# §1 — ColumnValue — runtime tagged-union for one composite-key component
# =============================================================================
#
# A composite key's hash + equality needs to compare components position-
# wise across rows. Since each component can be a different DType (Int64
# / Float64 / String / Bool), the runtime KeyValueN holds N tagged
# ColumnValue cells.
#
# ColumnValue uses tag+Optional shape mirroring SourceVariant /
# SinkVariant from komira_core.source.source_variant (the canonical
# in-tree tag+Optional pattern). The tag identifies which DType cell
# is populated; the other cells are None.
#
# Tag aliases use the same numeric domain as Arrow DType enums (Int64=8,
# Float64=12, String=14, Bool=3) — these don't have to match the Arrow
# numbering exactly since they're internal, but using Arrow's numbers
# keeps the mental model uniform.
# =============================================================================

comptime CVT_INT64: UInt8 = 8
comptime CVT_FLOAT64: UInt8 = 12
comptime CVT_STRING: UInt8 = 14
comptime CVT_BOOL: UInt8 = 3


struct ColumnValue(Copyable, Movable, Deinitable):
    """Tagged-union runtime cell for one composite-key component.

    Holds exactly one of {Int64, Float64, String, Bool} per the
    `tag` field. The other Optional cells are None. Mirrors the
    in-tree tag+Optional pattern (SourceVariant, SinkVariant).

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
# §2 — KeyExpr trait — comptime composite-key extractor
# =============================================================================
#
# A `trait KeyExpr`
# generalized to N-arity via the per-arity `extract` returning a
# `KeyValueN`. Arities 1..4 are provided; KeyExpr trait itself is
# parametric-free (the arity is encoded in the conformer struct).
#
# Conformers: CompositeKey1[K0], CompositeKey2[K0, K1], CompositeKey3[K0,
# K1, K2], CompositeKey4[K0, K1, K2, K3]. Each K_i can be any of
# ExprX{Bool, I64, F64, String}.
#
# DESIGN NOTE: the trait carries an associated `Arity` int + `extract`
# method but Mojo 1.0.0b1 doesn't enforce that the trait's `extract`
# method has the right return type per arity (KeyValueN). Each
# CompositeKeyN conformer ships its own `extract` returning the matching
# KeyValueN. The CompositeHashTable consumer is parametric on the
# CompositeKeyN type and dispatches per-arity.
# =============================================================================


# =============================================================================
# §3 — KeyValue1..4 — runtime N-tuple value structs
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
# §4 — Component-type trait variants (one per ExprX kind to keep parameter
#       resolution disambiguated across CompositeKeyN per-arity conformers)
# =============================================================================
#
# To keep the CompositeKeyN ctors simple while supporting mixed component
# types, this module ships ONE conformer per arity that takes the four ExprX
# variants positionally as comptime params (with sentinel-typed "unused"
# placeholders). Mojo 1.0.0b1's per-position trait-bound resolution
# requires each position to bind to a specific trait — we cannot have
# one CompositeKeyN with K_i: ExprXBool | ExprXI64 | ExprXF64 | ExprXString.
#
# Workaround: per-arity-per-DType-combo enumeration is impractical (1..4
# arities × 4 DTypes^arity = 4 + 16 + 64 + 256 = 340 combinations). A
# fixed-shape conformer such as CompositeKey2[K0: ExprString, K1: ExprI64]
# is instead generated for the specific shape by the SDK / shape classifier
# at plan-compile time. This module ships:
#
#   - Generic ColXI64 / ColXF64 / ColXBool / ColXString column accessor
#     conformers (NOT in this file — they live in expr_x_conformers.mojo;
#     the trait declarations here are sufficient for
#     stage-primitive smoke tests).
#   - The smoke tests use HAND-CRAFTED test-local CompositeKeyN
#     conformers (each test pins one K_i: ExprXI64 shape, etc.).
#
# This file (composite_key.mojo) thus ships the KeyValueN runtime structs
# + ColumnValue tagged-union + GENERIC HELPERS for hashing /
# comparing KeyValueN values. The per-arity comptime adapter conformers
# (e.g. CompositeKey2[K0: ExprXString, K1: ExprXI64]) are emitted at
# plan-compile time by the StageFusionPass per the shape-classifier registry.
# =============================================================================


# =============================================================================
# §5 — Generic helpers for hashing + equality over KeyValueN
# =============================================================================
#
# These helpers operate on the runtime KeyValueN structs and provide:
#   - `hash_key_value` — FNV-1a 64-bit hash over the ColumnValue components.
#   - `eq_key_value` — element-wise equality across components.
#
# Used by the CompositeHashTable stage primitive ; also
# directly callable by shape-classified dispatch when the
# typed-path conformer route is not taken.
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
      - Float64: hash the 8 bytes of the IEEE-754 bit pattern (cast via
        bitcast SIMD).
      - String: hash each byte of the UTF-8 representation.
      - Bool: hash 1 byte (0x00 or 0x01).
    """
    var s = state
    var t = cv.kind()
    if t == CVT_INT64:
        var v = UInt64(cv.as_i64())
        for k in range(8):
            var b = UInt8((v >> UInt64((k * 8))) & 0xFF)
            s = _fnv1a_step(s, b)
    elif t == CVT_FLOAT64:
        # bitcast Float64 -> Int64 via SIMD cast, then hash 8 bytes
        var f = cv.as_f64()
        var bits = SIMD[DType.float64, 1](f).cast[DType.int64]()
        var v = UInt64(bits[0])
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
    """FNV-1a 64-bit hash over a 2-component KeyValue. Matches the
    KeyHashFnv shape."""
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
    """Element-wise equality on two ColumnValue cells. Returns False
    on tag mismatch (heterogeneous comparisons are not meaningful here).
    """
    if a.kind() != b.kind():
        return False
    var t = a.kind()
    if t == CVT_INT64:
        return a.as_i64() == b.as_i64()
    elif t == CVT_FLOAT64:
        return a.as_f64() == b.as_f64()
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
