# Pins FNV-1a-64 against the published reference vectors.

from std.testing import TestSuite, assert_equal

from komira_core.eval.fnv1a_64 import (
    FNV1A_OFFSET_64,
    FNV1A_PRIME_64,
    fnv1a_64_over_bytes,
)


def test_constants() raises:
    assert_equal(FNV1A_OFFSET_64, UInt64(14695981039346656037))
    assert_equal(FNV1A_PRIME_64, UInt64(1099511628211))


def test_empty_is_offset_basis() raises:
    var s = String("")
    assert_equal(fnv1a_64_over_bytes(s.as_bytes()), UInt64(0xCBF29CE484222325))


def test_reference_vectors() raises:
    var a = String("a")
    assert_equal(fnv1a_64_over_bytes(a.as_bytes()), UInt64(0xAF63DC4C8601EC8C))
    var foobar = String("foobar")
    assert_equal(
        fnv1a_64_over_bytes(foobar.as_bytes()), UInt64(0x85944171F73967E8)
    )


def test_sub_span_matches_standalone() raises:
    var s = String("xxfoobaryy")
    var whole = s.as_bytes()
    var bar = String("bar")
    assert_equal(
        fnv1a_64_over_bytes(whole[5:8]), fnv1a_64_over_bytes(bar.as_bytes())
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
