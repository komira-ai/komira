# =============================================================================
# Regression: OwnedAlignedBuffer.with_capacity returns an EMPTY buffer.
# =============================================================================
#
# `with_capacity(n)` is documented as "at least `n` bytes, length 0. The
# Arrow-builder pattern." The plain constructor `OwnedAlignedBuffer(n)` admits
# all `n` bytes into the length window (its documented post-condition), and
# `with_capacity` used to return `Self(n)` unchanged, so its result had
# length `n`: a builder appending from `len()` would start after `n`
# uninitialised bytes.
#
# FAIL-BEFORE / PASS-AFTER: with the old body (`return Self(capacity)`),
# `test_with_capacity_is_empty` fails on its first assertion
# (`left: 100 right: 0`).
#
# The constructor test pins the other half of the contract, so a fix that
# changed the constructor instead of `with_capacity` also goes red.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


def test_with_capacity_is_empty() raises:
    """Length 0, capacity at least the request (rounded up to 64 bytes)."""
    var b = OwnedAlignedBuffer.with_capacity(100)
    assert_equal(b.len(), 0)
    assert_equal(b.length(), Int64(0))
    assert_equal(b.capacity(), 128)
    assert_equal(b.view_ro().len(), 0)


def test_with_capacity_builder_append() raises:
    """The builder pattern: write into the reserved bytes, then set_length."""
    var b = OwnedAlignedBuffer.with_capacity(16)
    var span = b.into_span_capacity()
    for i in range(16):
        span[i] = UInt8(i + 1)
    b.set_length(16)
    assert_equal(b.len(), 16)
    assert_equal(b.read_u8_at(0), UInt8(1))
    assert_equal(b.read_u8_at(15), UInt8(16))


def test_with_capacity_non_positive_is_empty() raises:
    """`<= 0` yields the unallocated empty buffer."""
    var z = OwnedAlignedBuffer.with_capacity(0)
    assert_equal(z.len(), 0)
    assert_equal(z.capacity(), 0)
    var n = OwnedAlignedBuffer.with_capacity(-5)
    assert_equal(n.len(), 0)
    assert_equal(n.capacity(), 0)


def test_constructor_length_is_capacity() raises:
    """The plain constructor keeps its documented `length == capacity`."""
    var b = OwnedAlignedBuffer(100)
    assert_equal(b.len(), 100)
    assert_true(b.capacity() >= 100)


def main() raises:
    var s = TestSuite()
    s.test[test_with_capacity_is_empty]()
    s.test[test_with_capacity_builder_append]()
    s.test[test_with_capacity_non_positive_is_empty]()
    s.test[test_constructor_length_is_capacity]()
    s^.run()
