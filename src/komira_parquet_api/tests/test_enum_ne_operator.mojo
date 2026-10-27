# =============================================================================
# Every enum's `__ne__`: false for the same byte, true for any other
# =============================================================================
#
# `__ne__` is written out beside `__eq__` on each enum (a defined operator, not the
# negation of `__eq__` the compiler would supply). It is `@always_inline`, so a test that writes `a != b` leaves
# no line of it in a report; the tests call it by name, with values built at run time: equal values compare not-unequal, and a value differs from
# its neighbour and from a value no name is defined for.

from std.testing import TestSuite, assert_false, assert_true

from komira_parquet_api import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
    FieldRepetitionType,
    BoundaryOrder,
)


def _values() -> List[Int]:
    """Values built at run time, so no comparison is folded away."""
    var out = List[Int]()
    out.append(0)
    out.append(1)
    out.append(200)
    return out^


def test_page_type_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, PageType(a).__ne__(PageType(b)))


def test_encoding_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, Encoding(a).__ne__(Encoding(b)))


def test_compression_codec_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, CompressionCodec(a).__ne__(CompressionCodec(b)))


def test_parquet_type_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, ParquetType(a).__ne__(ParquetType(b)))


def test_field_repetition_type_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, FieldRepetitionType(a).__ne__(FieldRepetitionType(b)))


def test_boundary_order_ne() raises:
    for a in _values():
        for b in _values():
            assert_equal_ne(a == b, BoundaryOrder(a).__ne__(BoundaryOrder(b)))


def assert_equal_ne(same: Bool, ne: Bool) raises:
    """`!=` is true exactly when the two values are not the same."""
    if same:
        assert_false(ne)
    else:
        assert_true(ne)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
