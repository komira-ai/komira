# =============================================================================
# test_firestore_cdc_cursor.mojo — falsifier: the CDC checkpoint-cursor
#   encode/decode + the read_time -> fixed-width-comparable-sequence normalization.
# =============================================================================
#
# CDC-Firestore ChangeSource (no network). The Firestore Watch CDC path feeds a
# generic ingest pipeline whose position seam has two primitives, a per-record
# SEQUENCE NUMBER (a decimal string compared by numeric magnitude) and one
# OPAQUE cursor string per shard. Firestore's two-part resumable position maps
# onto them:
#
#   * ORDERING KEY. Firestore's `read_time` (a google.protobuf.Timestamp:
#     seconds + nanos) normalizes to a FIXED-WIDTH ZERO-PADDED decimal string
#     (`seconds` in 12 digits + `nanos` in 9 digits = a 21-char string) used AS
#     `ChangeRecord.sequence_number`. At a fixed width, byte order IS numeric
#     order, so a consumer comparing by magnitude orders older < newer.
#
#   * CHECKPOINT CURSOR. The seam's single OPAQUE cursor String encodes the pair
#     `(read_time, resume_token)`; `open_shard(after)` decodes it back on resume.
#
# THE FALSIFIERS:
#   (1) read_time -> sequence: older read_time sorts BEFORE newer (across a
#       seconds bump AND a nanos-only bump); the string is fixed-width (21
#       chars) and all digits, so byte order and numeric order agree.
#   (2) composite cursor round-trip: encode (read_time_seconds, read_time_nanos,
#       resume_token bytes) -> a String -> decode back to the SAME parts
#       (byte-identical token, exact seconds/nanos).
#   (3) an EMPTY cursor (cold start) decodes to has_position=False (so the
#       driver cold-starts the watch) — distinct from a present cursor whose
#       resume_token happens to be empty.
#
# The ingest side's own use of the cursor (stored per shard in the table's
# snapshot summary) is that package's test, not this one.
#
# FAILS ON CURRENT CODE (pre-fix): firestore_cdc_cursor (read_time_to_sequence
# / encode_firestore_cursor / decode_firestore_cursor / FirestoreCursor) does not
# exist -> this file does not COMPILE.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_firestore.firestore_cdc_cursor import (
    read_time_to_sequence,
    encode_firestore_cursor,
    decode_firestore_cursor,
    FirestoreCursor,
)


# =============================================================================
# (1) read_time -> a fixed-width digit string whose byte order is numeric order.
# =============================================================================
def _all_digits(s: String) -> Bool:
    for b in s.as_bytes():
        if b < UInt8(ord("0")) or b > UInt8(ord("9")):
            return False
    return True


def test_read_time_sequence_orders_by_value() raises:
    print("  test_read_time_sequence_orders_by_value...")
    # older (earlier seconds) < newer (later seconds).
    var older = read_time_to_sequence(Int64(1_000_000), Int64(0))
    var newer = read_time_to_sequence(Int64(1_000_001), Int64(0))
    assert_true(newer > older, "newer read_time > older (seconds bump)")
    assert_false(older > newer, "older read_time NOT > newer")

    # same seconds, older nanos < newer nanos.
    var n_lo = read_time_to_sequence(Int64(1_000_000), Int64(1))
    var n_hi = read_time_to_sequence(Int64(1_000_000), Int64(999_999_999))
    assert_true(n_hi > n_lo, "higher nanos > lower nanos (same seconds)")
    assert_false(n_lo > n_hi, "lower nanos NOT > higher nanos")

    # a nanos rollover boundary: (s=10, nanos=999_999_999) < (s=11, nanos=0).
    var edge_lo = read_time_to_sequence(Int64(10), Int64(999_999_999))
    var edge_hi = read_time_to_sequence(Int64(11), Int64(0))
    assert_true(
        edge_hi > edge_lo,
        "a nanos-max at second N is LESS than nanos-0 at second N+1",
    )
    # A width change would break byte order (`9` > `10`); a width-padded value
    # spanning a digit-count boundary still orders by value.
    var w_lo = read_time_to_sequence(Int64(9), Int64(0))
    var w_hi = read_time_to_sequence(Int64(10), Int64(0))
    assert_true(w_hi > w_lo, "9 s < 10 s at a fixed width")

    # Every sequence is all digits, so a decimal-magnitude compare accepts it.
    assert_true(_all_digits(older) and _all_digits(n_hi) and _all_digits(edge_lo))
    # The sequence is FIXED WIDTH (12 seconds digits + 9 nanos digits = 21).
    assert_equal(older.byte_length(), 21, "fixed-width 21-char sequence")
    assert_equal(n_hi.byte_length(), 21, "fixed-width regardless of value")
    print("    OK")


# =============================================================================
# (2) composite cursor round-trip.
# =============================================================================
def test_cursor_roundtrip() raises:
    print("  test_cursor_roundtrip...")
    var token = List[UInt8]()
    token.append(UInt8(0x00))  # a leading zero byte (must survive hex encode)
    token.append(UInt8(0xAB))
    token.append(UInt8(0xCD))
    token.append(UInt8(0xFF))
    var cursor = encode_firestore_cursor(
        Int64(1_800_000_123), Int64(456_000_789), token
    )
    assert_true(cursor.byte_length() > 0, "a real cursor is non-empty")

    var decoded = decode_firestore_cursor(cursor)
    assert_true(decoded.has_position, "decoded cursor carries a position")
    assert_equal(decoded.read_time_seconds, Int64(1_800_000_123), "seconds")
    assert_equal(decoded.read_time_nanos, Int64(456_000_789), "nanos")
    assert_equal(len(decoded.resume_token), 4, "resume_token length")
    assert_equal(Int(decoded.resume_token[0]), 0x00, "leading zero byte survives")
    assert_equal(Int(decoded.resume_token[1]), 0xAB)
    assert_equal(Int(decoded.resume_token[2]), 0xCD)
    assert_equal(Int(decoded.resume_token[3]), 0xFF)

    # The cursor's ordering-key half equals read_time_to_sequence.
    assert_equal(
        decoded.sequence(),
        read_time_to_sequence(Int64(1_800_000_123), Int64(456_000_789)),
        "the cursor's sequence half == the normalized read_time",
    )
    print("    OK")


# =============================================================================
# (3) empty cursor (cold start).
# =============================================================================
def test_empty_cursor_is_cold_start() raises:
    print("  test_empty_cursor_is_cold_start...")
    var decoded = decode_firestore_cursor(String(""))
    assert_false(
        decoded.has_position,
        "an empty cursor means COLD START (the watch opens from the beginning)",
    )

    # A present cursor with an EMPTY resume_token is DISTINCT from a cold start.
    var empty_tok = List[UInt8]()
    var cursor = encode_firestore_cursor(Int64(5), Int64(6), empty_tok)
    var d2 = decode_firestore_cursor(cursor)
    assert_true(
        d2.has_position,
        "a present cursor with an empty resume_token is NOT a cold start",
    )
    assert_equal(len(d2.resume_token), 0, "the token is empty but present")
    assert_equal(d2.read_time_seconds, Int64(5))
    assert_equal(d2.read_time_nanos, Int64(6))
    print("    OK")


def main() raises:
    print("test_firestore_cdc_cursor (cursor encode/decode + read_time"
          " ordering key)")
    test_read_time_sequence_orders_by_value()
    test_cursor_roundtrip()
    test_empty_cursor_is_cold_start()
    print("ALL PASS")
