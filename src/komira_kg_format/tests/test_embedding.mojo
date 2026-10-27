# =============================================================================
# test_embedding.mojo -- the packed-embedding cell.
# =============================================================================
#
#   inverses     unpack(pack(v)) returns v: within the f32 narrowing for an f64
#                vector (dims 4, 16, all zero, negatives, a non-default 7), and
#                exactly for an f32 vector; packing the unpacked bytes again
#                gives the same bytes.
#   layout       the cell is dim * 4 bytes, little-endian f32: 1.0 is
#                00 00 80 3F, -2.0 is 00 00 00 C0; an all-zero vector is all
#                0x00 bytes and is not cut short.
#   bytes view   unpack_embedding_bytes reads a cell held in a List[UInt8]
#                through a Span, the form a column reader hands over, and
#                ignores a trailing partial component.
#   dimension    unpack_embedding_checked returns a cell of exactly the stated
#                dimension, and refuses a short cell, a long cell, a trailing
#                partial component, a dimension of zero or less, and a
#                dimension so large that dim * 4 overflows (1 << 62).
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_kg_format import (
    EMB_F32_BYTES,
    pack_embedding,
    pack_embedding_f32,
    unpack_embedding,
    unpack_embedding_bytes,
    unpack_embedding_checked,
)

comptime _TOL: Float64 = 1.0e-6


def _assert_close_roundtrip(v: List[Float64], label: String) raises:
    var packed = pack_embedding(v)
    var got = unpack_embedding(packed)
    assert_equal(len(got), len(v), label + ": dimension kept")
    for i in range(len(v)):
        assert_true(
            abs(got[i] - v[i]) <= _TOL,
            label + ": component " + String(i) + " within f32 tolerance",
        )
    # Packing what came back is byte-identical: unpack lost nothing that pack
    # had kept.
    var again = pack_embedding(got)
    assert_equal(len(again.as_bytes()), len(packed.as_bytes()), label)
    for i in range(len(packed.as_bytes())):
        assert_equal(again.as_bytes()[i], packed.as_bytes()[i], label)


def test_f64_roundtrip_dim4() raises:
    var a: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    _assert_close_roundtrip(a, "dim4 unit")
    var b: List[Float64] = [0.9, 0.1, 0.0, 0.0]
    _assert_close_roundtrip(b, "dim4 mixed")


def test_f64_roundtrip_dim16_non_f32_exact_values() raises:
    var v = List[Float64](capacity=16)
    for i in range(16):
        # 0.1 is not exact in f32, so this exercises the narrowing bound.
        v.append(Float64(i) * 0.1 - 0.55)
    _assert_close_roundtrip(v, "dim16")


def test_f64_roundtrip_all_zero_and_negatives() raises:
    var z: List[Float64] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    _assert_close_roundtrip(z, "zeros")
    var n: List[Float64] = [-1.0, -0.5, -123.25, -0.0009765625, 42.0, -7.5]
    _assert_close_roundtrip(n, "negatives")


def test_f64_roundtrip_non_default_dimension() raises:
    var v = List[Float64](capacity=7)
    for i in range(7):
        v.append(Float64(i) - 3.0)
    _assert_close_roundtrip(v, "dim7")
    assert_equal(len(pack_embedding(v).as_bytes()), 7 * EMB_F32_BYTES)


def test_f32_roundtrip_is_exact() raises:
    var v: List[Float32] = [1.5, -2.25, 0.0, 0.125, -64.0, 1.0e-30, 3.0e38]
    var got = unpack_embedding(pack_embedding_f32(v))
    assert_equal(len(got), len(v))
    for i in range(len(v)):
        assert_equal(got[i], Float64(v[i]), "f32 component " + String(i))


def test_f32_roundtrip_keeps_negative_zero_sign() raises:
    var v: List[Float32] = [-0.0]
    var got = unpack_embedding(pack_embedding_f32(v))
    assert_equal(len(got), 1)
    # -0.0 == 0.0, so look at the bytes: the sign bit survives.
    var bytes = pack_embedding_f32(v).as_bytes()
    assert_equal(Int(bytes[3]), 0x80)


def test_layout_is_little_endian_f32() raises:
    var one: List[Float32] = [1.0]
    var b = pack_embedding_f32(one).as_bytes()
    assert_equal(len(b), 4)
    assert_equal(Int(b[0]), 0x00)
    assert_equal(Int(b[1]), 0x00)
    assert_equal(Int(b[2]), 0x80)
    assert_equal(Int(b[3]), 0x3F)
    var two: List[Float32] = [-2.0, 1.0]
    var c = pack_embedding_f32(two).as_bytes()
    assert_equal(len(c), 8)
    assert_equal(Int(c[3]), 0xC0)
    assert_equal(Int(c[7]), 0x3F)


def test_byte_length_is_dim_times_four() raises:
    var v4: List[Float64] = [1.0, 2.0, 3.0, 4.0]
    assert_equal(len(pack_embedding(v4).as_bytes()), 4 * EMB_F32_BYTES)
    var v0 = List[Float64]()
    assert_equal(len(pack_embedding(v0).as_bytes()), 0)
    assert_equal(len(unpack_embedding(pack_embedding(v0))), 0)


def test_all_zero_cell_keeps_its_embedded_nulls() raises:
    var z: List[Float64] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    var packed = pack_embedding(z)
    var bytes = packed.as_bytes()
    assert_equal(len(bytes), 8 * EMB_F32_BYTES)
    for i in range(len(bytes)):
        assert_equal(Int(bytes[i]), 0, "byte " + String(i))
    assert_equal(len(unpack_embedding(packed)), 8)


def test_unpack_bytes_reads_a_list_through_a_span() raises:
    var v: List[Float32] = [0.5, -4.0, 8.0]
    var packed = pack_embedding_f32(v)
    var cell = List[UInt8]()
    for b in packed.as_bytes():
        cell.append(b)
    var got = unpack_embedding_bytes(Span(cell))
    assert_equal(len(got), 3)
    assert_equal(got[0], 0.5)
    assert_equal(got[1], -4.0)
    assert_equal(got[2], 8.0)
    # A trailing partial component is ignored by the unchecked reader.
    cell.append(UInt8(7))
    assert_equal(len(unpack_embedding_bytes(Span(cell))), 3)


def test_checked_accepts_exactly_the_stated_dimension() raises:
    var v: List[Float32] = [1.0, 2.0, 3.0]
    var cell = pack_embedding_f32(v)
    var got = unpack_embedding_checked(cell.as_bytes(), 3)
    assert_equal(len(got), 3)
    assert_equal(got[2], 3.0)


def test_checked_refuses_a_wrong_length_cell() raises:
    var v: List[Float32] = [1.0, 2.0, 3.0]
    var cell = pack_embedding_f32(v)
    with assert_raises(contains="not a dimension of 4"):
        _ = unpack_embedding_checked(cell.as_bytes(), 4)
    with assert_raises(contains="not a dimension of 2"):
        _ = unpack_embedding_checked(cell.as_bytes(), 2)
    var ragged = List[UInt8]()
    for b in cell.as_bytes():
        ragged.append(b)
    ragged.append(UInt8(1))
    with assert_raises(contains="13 bytes"):
        _ = unpack_embedding_checked(Span(ragged), 3)


def test_checked_refuses_a_dimension_whose_byte_size_overflows() raises:
    # 1 << 62 times 4 wraps to 0, which an empty cell would have matched.
    var empty = List[UInt8]()
    with assert_raises(contains="not a dimension of"):
        _ = unpack_embedding_checked(Span(empty), 1 << 62)
    with assert_raises(contains="not a dimension of"):
        _ = unpack_embedding_checked(Span(empty), (1 << 61) + 1)
    with assert_raises(contains="not a dimension of"):
        _ = unpack_embedding_checked(Span(empty), Int.MAX)
    var four = List[UInt8]()
    for _ in range(4):
        four.append(UInt8(0))
    with assert_raises(contains="not a dimension of"):
        _ = unpack_embedding_checked(Span(four), (1 << 62) + 1)


def test_checked_refuses_a_non_positive_dimension() raises:
    var empty = List[UInt8]()
    with assert_raises(contains="must be positive"):
        _ = unpack_embedding_checked(Span(empty), 0)
    with assert_raises(contains="must be positive"):
        _ = unpack_embedding_checked(Span(empty), -3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
