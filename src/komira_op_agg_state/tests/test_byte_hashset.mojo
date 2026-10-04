# =============================================================================
# test_byte_hashset.mojo — Option D byte-erased HashSet unit tests (Phase 1)
# =============================================================================
#
# Unit tests for an internal module
# per an internal doc §3 + §9.1.
#
# Coverage:
#   - Single I64 row round-trip (insert + contains + dedup).
#   - Arity-3 I64 packed-row correctness (24 bytes/row).
#   - Mixed-DType (I64, F64) packed-row correctness.
#   - String round-trip (variable-width via length prefix).
#   - High-arity (8+) correctness.
#
# Tests use a small caller-side typed serializer (mirrors what the SDK
# lowering arm + feed driver will emit at the runtime path).
# =============================================================================

from komira_op_agg_state.byte_hashset import ByteHashSet


# -----------------------------------------------------------------------------
# Caller-side typed serializers — mirror SDK lowering emitters.
# -----------------------------------------------------------------------------


@always_inline
def _append_i64_le(mut row: List[UInt8], v: Int64):
    """Append Int64 little-endian (8 bytes)."""
    var u = UInt64(v)
    var k = 0
    while k < 8:
        row.append(UInt8((u >> (UInt64(k) * 8)) & 0xFF))
        k = k + 1


@always_inline
def _append_f64_le(mut row: List[UInt8], v: Float64):
    """Append Float64 little-endian (8 bytes, via bitcast)."""
    var u = UnsafePointer(to=v).bitcast[UInt64]()[]
    var k = 0
    while k < 8:
        row.append(UInt8((u >> (UInt64(k) * 8)) & 0xFF))
        k = k + 1


@always_inline
def _append_string_lenprefixed(mut row: List[UInt8], imm s: String):
    """Append String as UInt32 LE length-prefix + UTF-8 bytes."""
    var n = UInt32(s.byte_length())
    var k = 0
    while k < 4:
        row.append(UInt8((n >> (UInt32(k) * 8)) & 0xFF))
        k = k + 1
    var bs = s.as_bytes()
    var j = 0
    while j < len(bs):
        row.append(bs[j])
        j = j + 1


comptime _FNV_OFFSET: UInt64 = 14695981039346656037
comptime _FNV_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv1a_bytes(imm row: List[UInt8]) -> UInt64:
    """FNV-1a hash over byte slice."""
    var s = _FNV_OFFSET
    for i in range(len(row)):
        s = (s ^ UInt64(row[i])) * _FNV_PRIME
    return s


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_byte_hashset_single_i64() raises:
    """Single Int64 row — minimal correctness."""
    var s = ByteHashSet()
    if s.size() != 0:
        raise Error("ByteHashSet initial size != 0")

    var row1 = List[UInt8](capacity=8)
    _append_i64_le(row1, Int64(42))
    var h1 = _fnv1a_bytes(row1)

    var added_1 = s.insert_serialized(h1, Span(row1))
    if not added_1:
        raise Error("first insert should be NEW")
    if s.size() != 1:
        raise Error("size != 1 after first insert")

    # Second identical row — DUP.
    var row1_dup = List[UInt8](capacity=8)
    _append_i64_le(row1_dup, Int64(42))
    var h1_dup = _fnv1a_bytes(row1_dup)
    var added_dup = s.insert_serialized(h1_dup, Span(row1_dup))
    if added_dup:
        raise Error("duplicate insert should be DUP")
    if s.size() != 1:
        raise Error("size changed on duplicate")

    # Distinct row.
    var row2 = List[UInt8](capacity=8)
    _append_i64_le(row2, Int64(99))
    var h2 = _fnv1a_bytes(row2)
    var added_2 = s.insert_serialized(h2, Span(row2))
    if not added_2:
        raise Error("second distinct insert should be NEW")
    if s.size() != 2:
        raise Error("size != 2 after distinct insert")

    # Probe present.
    var probe_42 = List[UInt8](capacity=8)
    _append_i64_le(probe_42, Int64(42))
    var ph_42 = _fnv1a_bytes(probe_42)
    if not s.contains_serialized(ph_42, Span(probe_42)):
        raise Error("probe 42 should hit")

    # Probe absent.
    var probe_abs = List[UInt8](capacity=8)
    _append_i64_le(probe_abs, Int64(1234))
    var ph_abs = _fnv1a_bytes(probe_abs)
    if s.contains_serialized(ph_abs, Span(probe_abs)):
        raise Error("probe 1234 should miss")

    print("test_byte_hashset_single_i64 PASS")


def test_byte_hashset_arity3_i64() raises:
    """Arity-3 all-I64 — 24 bytes/row. POC validated 2.00× tax vs
    hardcoded HashSetI64I64I64 at this shape."""
    var s = ByteHashSet()

    var r1 = List[UInt8](capacity=24)
    _append_i64_le(r1, Int64(1))
    _append_i64_le(r1, Int64(2))
    _append_i64_le(r1, Int64(3))
    var h1 = _fnv1a_bytes(r1)
    _ = s.insert_serialized(h1, Span(r1))

    var r2 = List[UInt8](capacity=24)
    _append_i64_le(r2, Int64(1))
    _append_i64_le(r2, Int64(2))
    _append_i64_le(r2, Int64(4))
    var h2 = _fnv1a_bytes(r2)
    _ = s.insert_serialized(h2, Span(r2))

    # Dup
    var r1d = List[UInt8](capacity=24)
    _append_i64_le(r1d, Int64(1))
    _append_i64_le(r1d, Int64(2))
    _append_i64_le(r1d, Int64(3))
    var h1d = _fnv1a_bytes(r1d)
    var was_dup = s.insert_serialized(h1d, Span(r1d))
    if was_dup:
        raise Error("(1,2,3) duplicate should NOT insert")

    if s.size() != 2:
        raise Error(
            "arity-3 expected size=2, got " + String(s.size())
        )

    print("test_byte_hashset_arity3_i64 PASS — size=2, dedup OK")


def test_byte_hashset_mixed_i64_f64() raises:
    """Mixed-DType arity-2 (I64, F64) — validates packed-row encoding
    handles non-I64 cells correctly."""
    var s = ByteHashSet()

    var r1 = List[UInt8](capacity=16)
    _append_i64_le(r1, Int64(7))
    _append_f64_le(r1, Float64(1.5))
    var h1 = _fnv1a_bytes(r1)
    _ = s.insert_serialized(h1, Span(r1))

    var r2 = List[UInt8](capacity=16)
    _append_i64_le(r2, Int64(7))
    _append_f64_le(r2, Float64(2.5))
    var h2 = _fnv1a_bytes(r2)
    _ = s.insert_serialized(h2, Span(r2))

    var r1d = List[UInt8](capacity=16)
    _append_i64_le(r1d, Int64(7))
    _append_f64_le(r1d, Float64(1.5))
    var h1d = _fnv1a_bytes(r1d)
    var was_dup = s.insert_serialized(h1d, Span(r1d))
    if was_dup:
        raise Error("mixed (7, 1.5) dup should NOT insert")

    if s.size() != 2:
        raise Error("mixed expected size=2, got " + String(s.size()))

    print("test_byte_hashset_mixed_i64_f64 PASS")


def test_byte_hashset_string_roundtrip() raises:
    """String round-trip — variable-width key via length prefix.
    Matches POC §247 (mixed-DType correctness)."""
    var s = ByteHashSet()

    var r1 = List[UInt8](capacity=16)
    _append_i64_le(r1, Int64(1))
    _append_string_lenprefixed(r1, String("foo"))
    var h1 = _fnv1a_bytes(r1)
    _ = s.insert_serialized(h1, Span(r1))

    var r2 = List[UInt8](capacity=16)
    _append_i64_le(r2, Int64(2))
    _append_string_lenprefixed(r2, String("bar"))
    var h2 = _fnv1a_bytes(r2)
    _ = s.insert_serialized(h2, Span(r2))

    # Dup
    var r1d = List[UInt8](capacity=16)
    _append_i64_le(r1d, Int64(1))
    _append_string_lenprefixed(r1d, String("foo"))
    var h1d = _fnv1a_bytes(r1d)
    var was_dup = s.insert_serialized(h1d, Span(r1d))
    if was_dup:
        raise Error("String dup should NOT insert")

    # Case-sensitive distinct
    var r3 = List[UInt8](capacity=16)
    _append_i64_le(r3, Int64(1))
    _append_string_lenprefixed(r3, String("FOO"))
    var h3 = _fnv1a_bytes(r3)
    var was_new = s.insert_serialized(h3, Span(r3))
    if not was_new:
        raise Error("String FOO (case-distinct) should INSERT")

    if s.size() != 3:
        raise Error("String expected size=3, got " + String(s.size()))

    print("test_byte_hashset_string_roundtrip PASS — case-sensitive OK")


def test_byte_hashset_arity8_correctness() raises:
    """Arity-8 all-I64 — 64 bytes/row. Validates ByteHashSet at the
    arity boundary above which parametric HashSetN[K0..K7] is the only
    typed option."""
    var s = ByteHashSet()

    var r1 = List[UInt8](capacity=64)
    for k in range(8):
        _append_i64_le(r1, Int64(k + 1))
    var h1 = _fnv1a_bytes(r1)
    _ = s.insert_serialized(h1, Span(r1))

    var r1d = List[UInt8](capacity=64)
    for k in range(8):
        _append_i64_le(r1d, Int64(k + 1))
    var h1d = _fnv1a_bytes(r1d)
    var was_dup = s.insert_serialized(h1d, Span(r1d))
    if was_dup:
        raise Error("arity-8 dup should NOT insert")

    var r2 = List[UInt8](capacity=64)
    for k in range(7):
        _append_i64_le(r2, Int64(k + 1))
    _append_i64_le(r2, Int64(99))  # different last cell
    var h2 = _fnv1a_bytes(r2)
    var was_new = s.insert_serialized(h2, Span(r2))
    if not was_new:
        raise Error("arity-8 distinct (last cell diff) should INSERT")

    if s.size() != 2:
        raise Error(
            "arity-8 expected size=2, got " + String(s.size())
        )

    print("test_byte_hashset_arity8_correctness PASS")


def main() raises:
    test_byte_hashset_single_i64()
    test_byte_hashset_arity3_i64()
    test_byte_hashset_mixed_i64_f64()
    test_byte_hashset_string_roundtrip()
    test_byte_hashset_arity8_correctness()
    print("ALL test_byte_hashset.mojo tests PASS (5/5)")
