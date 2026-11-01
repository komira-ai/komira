# =============================================================================
# iceberg_bounds.mojo — Iceberg single-value serialization + per-column stats.
# =============================================================================
#
# The manifest's lower_bounds (125) / upper_bounds (128) maps store, per
# field-id, ONE serialized value (the column min / max) using Iceberg's
# "single-value serialization" (table spec Appendix D). A reader uses these to
# PRUNE a data file whose [lower, upper] cannot satisfy a predicate, so the
# byte form must be EXACTLY what the spec mandates or the bound is silently
# mis-compared (a correctness hazard, not just a perf one):
#
#   boolean : 1 byte (0x00 false / 0x01 true)
#   int     : 4 bytes, little-endian two's-complement
#   long    : 8 bytes, little-endian two's-complement
#   float   : 4 bytes, little-endian IEEE-754 binary32
#   double  : 8 bytes, little-endian IEEE-754 binary64
#   string  : UTF-8 bytes, NO length prefix
#
# This module owns (a) the scalar serializers and (b) the typed min/max scan
# helpers that compute a `ColumnBound` from an Arrow array. Null cells are
# EXCLUDED from min/max (a null is not a candidate bound) and counted into the
# bound's `null_count`. NaN is excluded from float/double bounds (the spec
# forbids a NaN bound), and a zero bound is -0.0 for the lower bound and +0.0
# for the upper one, so a bound is never above or below a value it covers.
#
# Encapsulation: public helpers take borrowed Arrow arrays / typed scalars and
# return owned `List[UInt8]` / `ColumnBound`. ZERO UnsafePointer in any
# signature; ZERO wildcard origins.
# =============================================================================

from std.memory import bitcast

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

from .iceberg_types import ColumnBound


# =============================================================================
# Scalar single-value serializers.
# =============================================================================


@always_inline
def serialize_boolean(v: Bool) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(1) if v else UInt8(0))
    return out^


@always_inline
def serialize_int32(v: Int32) -> List[UInt8]:
    """4-byte little-endian two's-complement."""
    var bits = bitcast[DType.uint32, 1](v)
    var out = List[UInt8](capacity=4)
    out.append(UInt8(bits & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(8)) & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(16)) & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(24)) & UInt32(0xFF)))
    return out^


@always_inline
def serialize_int64(v: Int64) -> List[UInt8]:
    """8-byte little-endian two's-complement."""
    var bits = bitcast[DType.uint64, 1](v)
    var out = List[UInt8](capacity=8)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


@always_inline
def serialize_float32(v: Float32) -> List[UInt8]:
    """4-byte little-endian IEEE-754 binary32."""
    var bits = bitcast[DType.uint32, 1](v)
    var out = List[UInt8](capacity=4)
    out.append(UInt8(bits & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(8)) & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(16)) & UInt32(0xFF)))
    out.append(UInt8((bits >> UInt32(24)) & UInt32(0xFF)))
    return out^


@always_inline
def serialize_float64(v: Float64) -> List[UInt8]:
    """8-byte little-endian IEEE-754 binary64."""
    var bits = bitcast[DType.uint64, 1](v)
    var out = List[UInt8](capacity=8)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


@always_inline
def serialize_string(s: String) -> List[UInt8]:
    """UTF-8 bytes, NO length prefix."""
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


@always_inline
def serialize_bytes(b: List[UInt8]) -> List[UInt8]:
    """Single-value serialization of an opaque byte range: the bytes verbatim,
    NO length prefix.

    The byte-faithful sibling of `serialize_string` for a key whose bytes are
    NOT round-trippable through `String`: an opaque key with bytes >= 0x80. A
    `chr(Int(b))`-per-byte `String` round-trip would expand each such byte to a
    2-byte UTF-8 sequence, making the serialized bound LONGER THAN and
    lexicographically DIFFERENT from the true key, which silently mis-prunes a
    data file. Serializing the raw bytes directly is the spec form for a binary
    column."""
    return b.copy()


# =============================================================================
# Zero bounds: -0.0 and +0.0 compare equal, so a min/max scan keeps whichever
# came first. Iceberg orders -0.0 below +0.0, so a lower bound of 0 is written
# as -0.0 and an upper bound of 0 as +0.0: the bound then covers both.


@always_inline
def _lower_zero32(v: Float32) -> Float32:
    return bitcast[DType.float32, 1](UInt32(0x80000000)) if v == Float32(0) else v


@always_inline
def _upper_zero32(v: Float32) -> Float32:
    return Float32(0) if v == Float32(0) else v


@always_inline
def _lower_zero64(v: Float64) -> Float64:
    return bitcast[DType.float64, 1](UInt64(0x8000000000000000)) if v == Float64(0) else v


@always_inline
def _upper_zero64(v: Float64) -> Float64:
    return Float64(0) if v == Float64(0) else v


# =============================================================================
# Typed min/max scans -> ColumnBound.
# =============================================================================
#
# Each helper walks one Arrow column, skipping null cells, accumulating the
# min + max + null_count + value_count, and serializes the min/max into the
# single-value byte form. An ALL-NULL (or empty) column yields a bound with no
# lower/upper (None) — the manifest omits that field-id from the bound maps.


def bound_int32(
    field_id: Int, arr: PrimitiveArray[DType.int32]
) raises -> ColumnBound:
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = Int32(0)
    var mx = Int32(0)
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if not have:
            mn = v
            mx = v
            have = True
        else:
            if v < mn:
                mn = v
            if v > mx:
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_int32(mn)),
        Optional[List[UInt8]](serialize_int32(mx)),
        null_count,
        value_count,
    )


def bound_int64(
    field_id: Int, arr: PrimitiveArray[DType.int64]
) raises -> ColumnBound:
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = Int64(0)
    var mx = Int64(0)
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if not have:
            mn = v
            mx = v
            have = True
        else:
            if v < mn:
                mn = v
            if v > mx:
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_int64(mn)),
        Optional[List[UInt8]](serialize_int64(mx)),
        null_count,
        value_count,
    )


def bound_float32(
    field_id: Int, arr: PrimitiveArray[DType.float32]
) raises -> ColumnBound:
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = Float32(0)
    var mx = Float32(0)
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if v != v:
            # NaN is never a bound (spec): it is neither below nor above any value.
            continue
        if not have:
            mn = v
            mx = v
            have = True
        else:
            if v < mn:
                mn = v
            if v > mx:
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_float32(_lower_zero32(mn))),
        Optional[List[UInt8]](serialize_float32(_upper_zero32(mx))),
        null_count,
        value_count,
    )


def bound_float64(
    field_id: Int, arr: PrimitiveArray[DType.float64]
) raises -> ColumnBound:
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = Float64(0)
    var mx = Float64(0)
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if v != v:
            # NaN is never a bound (spec): it is neither below nor above any value.
            continue
        if not have:
            mn = v
            mx = v
            have = True
        else:
            if v < mn:
                mn = v
            if v > mx:
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_float64(_lower_zero64(mn))),
        Optional[List[UInt8]](serialize_float64(_upper_zero64(mx))),
        null_count,
        value_count,
    )


def bound_boolean(field_id: Int, arr: BooleanArray) raises -> ColumnBound:
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = True
    var mx = False
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if not have:
            mn = v
            mx = v
            have = True
        else:
            # min(false<true): min stays the AND-ish smallest; serialize the
            # actual boolean min/max (false < true).
            if (not v) and mn:
                mn = v
            if v and (not mx):
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_boolean(mn)),
        Optional[List[UInt8]](serialize_boolean(mx)),
        null_count,
        value_count,
    )


def bound_string(
    field_id: Int, arr: StringArray[HeapRegion]
) raises -> ColumnBound:
    """UTF-8 lexicographic (byte-wise) min/max. Iceberg compares string bounds
    by unsigned byte order, which byte-wise lexicographic comparison gives."""
    var n = arr.length
    var null_count = 0
    var have = False
    var mn = String("")
    var mx = String("")
    for i in range(n):
        if arr.is_null(i):
            null_count += 1
            continue
        var v = arr.get(i)
        if not have:
            mn = v
            mx = v
            have = True
        else:
            if _str_lt(v, mn):
                mn = v
            if _str_lt(mx, v):
                mx = v
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, null_count, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_string(mn)),
        Optional[List[UInt8]](serialize_string(mx)),
        null_count,
        value_count,
    )


@always_inline
def _str_lt(a: String, b: String) -> Bool:
    """Unsigned byte-wise lexicographic `a < b` (Iceberg string sort order)."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var la = len(ab)
    var lb = len(bb)
    var m = la if la < lb else lb
    for i in range(m):
        var x = Int(ab[i])
        var y = Int(bb[i])
        if x != y:
            return x < y
    return la < lb


@always_inline
def _bytes_lt(a: List[UInt8], b: List[UInt8]) -> Bool:
    """Unsigned byte-wise lexicographic `a < b`: the BINARY sort order Iceberg
    uses for a BYTE_ARRAY column with no UTF8 ConvertedType."""
    var la = len(a)
    var lb = len(b)
    var m = la if la < lb else lb
    for i in range(m):
        var x = Int(a[i])
        var y = Int(b[i])
        if x != y:
            return x < y
    return la < lb


def bound_bytes(
    field_id: Int, keys: List[List[UInt8]]
) raises -> ColumnBound:
    """Byte-exact BINARY min/max over a list of raw opaque byte-keys.

    The byte-faithful sibling of `bound_string` for a column that is TRUE
    binary: keys that carry `0x00` separators and bytes >= 0x80. `bound_string`
    routes each key through a `String`, which is lossy for bytes that are not
    valid UTF-8. This helper compares the raw bytes directly (`_bytes_lt`) and
    serializes the min/max verbatim (`serialize_bytes`, no length prefix, no
    UTF-8 interpretation), so the bound recalls the key range byte-exactly.

    The keys are never null; an empty list yields a bound with no lower/upper
    (None)."""
    var n = len(keys)
    var have = False
    var mn = List[UInt8]()
    var mx = List[UInt8]()
    for i in range(n):
        ref v = keys[i]
        if not have:
            mn = v.copy()
            mx = v.copy()
            have = True
        else:
            if _bytes_lt(v, mn):
                mn = v.copy()
            if _bytes_lt(mx, v):
                mx = v.copy()
    var value_count = n
    if not have:
        return ColumnBound(field_id, None, None, 0, value_count)
    return ColumnBound(
        field_id,
        Optional[List[UInt8]](serialize_bytes(mn)),
        Optional[List[UInt8]](serialize_bytes(mx)),
        0,
        value_count,
    )
