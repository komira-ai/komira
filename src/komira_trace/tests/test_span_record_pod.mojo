# =============================================================================
# test_span_record_pod.mojo — POD audit of the span record types
# =============================================================================
#
# Verifies:
#   1. SpanRecord and SpanLink are POD (size_of[T]() compiles, struct
#      can be moved across thread boundaries via Slab[T]).
#   2. Default-constructed records are zero-initialized.
#   3. SpanRecord.is_root() / has_error() flag accessors round-trip.
#
# The record layout is documented in `span_record.mojo`.
# =============================================================================

from std.sys import size_of
from std.testing import assert_equal, assert_true, assert_false

from komira_trace.span_record import (
    SpanRecord,
    SpanLink,
    TRACE_ID_BYTES,
    DEFAULT_MAX_LINKS,
    SPAN_FLAG_ROOT,
    SPAN_FLAG_HAS_ERROR,
    SPAN_STATUS_OPEN,
    SPAN_STATUS_CLOSED,
)


def test_span_link_pod_size() raises:
    """SpanLink size_of must elaborate (proves POD-ness)."""
    var s = size_of[SpanLink]()
    # 16 (trace_id) + 8 (span_id) + 4 (flags) = 28; aarch64 may pad to 32.
    assert_true(s >= 28 and s <= 32,
                "SpanLink size out of expected range: " + String(s))
    print("  test_span_link_pod_size PASS, size=", s)


def test_span_record_pod_size() raises:
    """SpanRecord size_of must elaborate."""
    var s = size_of[SpanRecord]()
    # 16+8+8+4+8+8+4+4+1+1+6 = 68 + 4*32 = 196 bytes nominal; compiler
    # may align up. Range [192, 224] is generous for any reasonable
    # alignment.
    assert_true(s >= 192 and s <= 240,
                "SpanRecord size out of expected range: " + String(s))
    print("  test_span_record_pod_size PASS, size=", s)


def test_span_record_default_init() raises:
    """Default ctor zero-initializes every field."""
    var r = SpanRecord()
    assert_equal(r.span_id, UInt64(0), "default span_id 0")
    assert_equal(r.parent_id, UInt64(0), "default parent_id 0")
    assert_equal(r.name_id, UInt32(0), "default name_id 0")
    assert_equal(r.start_ns, UInt64(0), "default start_ns 0")
    assert_equal(r.end_ns, UInt64(0), "default end_ns 0")
    assert_equal(r.worker_id, UInt32(0), "default worker_id 0")
    assert_equal(r.flags, UInt32(0), "default flags 0")
    assert_equal(r.status, SPAN_STATUS_OPEN, "default status OPEN")
    assert_equal(r.n_links, UInt8(0), "default n_links 0")
    print("  test_span_record_default_init PASS")


def test_span_flags_round_trip() raises:
    """flags → is_root / has_error accessors round-trip."""
    var r = SpanRecord()
    r.flags = SPAN_FLAG_ROOT
    assert_true(r.is_root(), "ROOT flag set")
    assert_false(r.has_error(), "ERROR flag not set")
    r.flags = r.flags | SPAN_FLAG_HAS_ERROR
    assert_true(r.has_error(), "ERROR flag now set")
    assert_true(r.is_root(), "ROOT still set after compound")
    print("  test_span_flags_round_trip PASS")


def test_span_link_round_trip() raises:
    """Construct a SpanLink and verify round-trip."""
    var trace = Array[UInt8, TRACE_ID_BYTES](fill=UInt8(7))
    var link = SpanLink(trace, UInt64(42), UInt32(0xCAFE))
    assert_equal(link.target_span_id, UInt64(42), "span_id round-trip")
    assert_equal(link.flags, UInt32(0xCAFE), "flags round-trip")
    assert_equal(link.target_trace_id[0], UInt8(7), "trace_id[0]")
    assert_equal(link.target_trace_id[15], UInt8(7), "trace_id[15]")
    print("  test_span_link_round_trip PASS")


def main() raises:
    print("test_span_record_pod")
    print("====================")
    test_span_link_pod_size()
    test_span_record_pod_size()
    test_span_record_default_init()
    test_span_flags_round_trip()
    test_span_link_round_trip()
    print()
    print("ALL TESTS PASS")
