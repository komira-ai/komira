# =============================================================================
# test_telemetry_codec_agreement.mojo
#   The one-definition test: it fails if a second `TelemetrySegmentEntry` ever
#   comes back, and it fails if either historical "version 1" layout is ever
#   decoded instead of refused.
# =============================================================================
#
# `komira_telemetry_store` (write) and `komira_telemetry_read` (read) once each
# defined a struct named `TelemetrySegmentEntry`, each stamped `version = 1`, and
# each had its own `encode_`/`decode_telemetry_segment_entry`, with different
# field orders:
#
#   layout A (write side): [ver][uuid16][LP object_key][min_ts][max_ts]
#                          [min_sid][max_sid][rows][bytes][merge_ops]
#                          [LP merge_uuids][sidecar]
#   layout B (read side):  [ver][uuid16][min_ts][max_ts][min_sid][max_sid]
#                          [rows][bytes][merge_ops][sidecar][LP object_key]
#                          [LP merge_uuids]
#
# Because the version bytes agreed, neither decoder refused the other's bytes.
# Cross-decoding the write side's own encoder output over key lengths 1..139
# returned without raising at some lengths, and at one of them reported an empty
# object key and the key's length as a minimum timestamp: a range that overlaps
# every query, reached with no error.
#
# What this file pins, in two parts:
# 1. One definition. The record lives in `komira_telemetry_store.segment_entry`
#    and the read package re-exports it. Both import paths below name the same
#    struct, and CASE 2 goes red on the byte comparison if they ever stop.
# 2. The version byte means something. Version 1 is reserved: it is an ambiguity,
#    not an old format, and the decoder refuses it by name. The current format is
#    version 2. CASES 0 and 1 hand the decoder a record in each historical order
#    and require a raise.
#
# Hermetic: pure bytes. No store, no I/O, no clock.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

# PATH 1 — the record's HOME, imported directly.
from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TELEMETRY_SEGMENT_ENTRY_VERSION_RESERVED,
    TELEMETRY_UUID_BYTES,
    decode_telemetry_segment_entry as store_decode,
    encode_telemetry_segment_entry as store_encode,
    make_log_segment_entry,
)

# PATH 2 — the SAME record, reached through the read package's facade, which is
# how `scan_plan.mojo` and every reader consumer sees it.
from komira_telemetry_read import (
    decode_telemetry_segment_entry as read_decode,
    encode_telemetry_segment_entry as read_encode,
    make_raw_segment_entry,
)


comptime _KEY: String = "telemetry/logs/20260902/data/0123456789abcdef0123456789abcdef.parquet"
comptime _MIN_TS: Int64 = 1788307200000000000
comptime _MAX_TS: Int64 = 1788307259999999999
comptime _ROWS: Int64 = 4211
comptime _BYTES: Int64 = 17593

comptime _SILENT_KEY: String = "telemetry/logs/20260902/data/aaaa"
"""EXACTLY 33 bytes — the measured centre of the pre-fix SILENT band, where a
cross-decode returned garbage and raised nothing. Do not "tidy" this string: its
LENGTH is the experimental condition."""


def _uuid(fill: UInt8) -> InlineArray[UInt8, TELEMETRY_UUID_BYTES]:
    return InlineArray[UInt8, TELEMETRY_UUID_BYTES](fill=fill)


def _put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _put_lp(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _put_i64(out, Int64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _legacy_layout_a(key: String) -> List[UInt8]:
    """A version-1 body in the WRITE side's historical field order. Hand-built
    on purpose — the encoder that produced this shape no longer exists, and a
    test that could only make bytes the current encoder makes could not pose
    this question at all."""
    var out = List[UInt8]()
    out.append(TELEMETRY_SEGMENT_ENTRY_VERSION_RESERVED)
    for _ in range(TELEMETRY_UUID_BYTES):
        out.append(UInt8(0xA5))
    _put_lp(out, key)
    _put_i64(out, _MIN_TS)
    _put_i64(out, _MAX_TS)
    _put_i64(out, Int64(0))
    _put_i64(out, Int64(0))
    _put_i64(out, _ROWS)
    _put_i64(out, _BYTES)
    _put_i64(out, Int64(0))
    _put_i64(out, Int64(0))
    out.append(UInt8(1))
    return out^


def _legacy_layout_b(key: String) -> List[UInt8]:
    """A version-1 body in the READ side's historical field order — fixed-width
    fields first, `has_text_sidecar` tenth, the key and the merge blob trailing.
    """
    var out = List[UInt8]()
    out.append(TELEMETRY_SEGMENT_ENTRY_VERSION_RESERVED)
    for _ in range(TELEMETRY_UUID_BYTES):
        out.append(UInt8(0xA5))
    _put_i64(out, _MIN_TS)
    _put_i64(out, _MAX_TS)
    _put_i64(out, Int64(0))
    _put_i64(out, Int64(0))
    _put_i64(out, _ROWS)
    _put_i64(out, _BYTES)
    _put_i64(out, Int64(0))
    out.append(UInt8(1))
    _put_lp(out, key)
    _put_i64(out, Int64(0))
    return out^


def _refusal_message(body: List[UInt8]) -> String:
    """Decode and return the raised message, or `""` if it did NOT raise.

    THE MESSAGE IS READ, NOT JUST THE FACT OF A RAISE. A truncation check
    would also raise on these bodies, go green, and leave the version arm this
    file is named for completely unexercised — which is how the original defect
    survived two suites that both had an "unknown version is refused" case."""
    try:
        var e = decode_probe(body)
        _ = e
        return String("")
    except err:
        return String(err)


def decode_probe(body: List[UInt8]) raises -> Int:
    var e = store_decode(body)
    return Int(e.row_count)


def _has(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# =============================================================================
# CASE 0 — THE VERSION BYTE NOW MEANS SOMETHING. A record in the READ
#          side's historical order is REFUSED, LOUDLY, NAMING WHAT IT SAW.
# =============================================================================


def test_00_the_read_sides_legacy_layout_is_refused_by_name() raises:
    var msg = _refusal_message(_legacy_layout_b(_KEY))
    print("  [case 0] refusal = " + msg)
    assert_true(
        msg.byte_length() > 0,
        "0: a version-1 body MUST raise. Returning an entry here is the"
        " original defect exactly: plausible garbage, no error",
    )
    assert_true(
        _has(msg, "version 1") and _has(msg, "reserved"),
        "0: the refusal must NAME WHAT IT SAW. 'corrupt manifest chunk' sends"
        " an operator looking for object-store corruption that does not exist;"
        " the chunk is intact and the LAYOUT is what disagrees. Got: " + msg,
    )


# =============================================================================
# CASE 1 — the WRITE side's own historical order is refused too. Version 1 is
#          reserved for BOTH, not resolved in this side's favour.
# =============================================================================


def test_01_the_write_sides_legacy_layout_is_refused_too() raises:
    var msg = _refusal_message(_legacy_layout_a(_KEY))
    print("  [case 1] refusal = " + msg)
    assert_true(
        msg.byte_length() > 0,
        "1: this side's OWN legacy bytes must raise as well. Accepting them"
        " would make version 1 mean 'layout A', which is precisely the guess"
        " that cannot be justified — the same byte also meant layout B",
    )
    assert_true(
        _has(msg, "version 1"),
        "1: refused by name, same as CASE 0. Got: " + msg,
    )
    assert_equal(
        Int(TELEMETRY_SEGMENT_ENTRY_VERSION),
        2,
        "1: the live format is version 2. If this is back to 1, an ambiguous"
        " byte is being written again",
    )


# =============================================================================
# CASE 2 — ONE DEFINITION. The write package's import path and the read
#          package's facade must produce the IDENTICAL envelope.
# =============================================================================


def test_02_both_import_paths_are_one_codec() raises:
    var a = make_log_segment_entry(
        _uuid(UInt8(0x11)), _KEY, _MIN_TS, _MAX_TS, _ROWS, _BYTES, False
    )
    var b = make_raw_segment_entry(
        _KEY, _MIN_TS, _MAX_TS, _ROWS, _BYTES, _uuid(UInt8(0x11))
    )
    var ab = store_encode(a)
    var bb = read_encode(b)

    assert_equal(
        len(ab),
        len(bb),
        "2: two reachable encoders of ONE format cannot disagree on the length"
        " of the same record",
    )
    var first_diff = -1
    for i in range(len(ab)):
        if ab[i] != bb[i]:
            first_diff = i
            break
    if first_diff >= 0:
        print(
            "  [case 2] FIRST DIFFERING BYTE at offset "
            + String(first_diff)
            + ": store="
            + String(Int(ab[first_diff]))
            + " read="
            + String(Int(bb[first_diff]))
        )
    assert_equal(
        first_diff,
        -1,
        "2: byte-for-byte identity across BOTH import paths. A non-(-1)"
        " offset here means a second definition of TelemetrySegmentEntry has"
        " come back into the tree",
    )

    # And the cross-decode, in both directions, on the record that used to be
    # the silent one.
    var silent = make_log_segment_entry(
        _uuid(UInt8(0xA5)), _SILENT_KEY, _MIN_TS, _MAX_TS, _ROWS, _BYTES, True
    )
    assert_equal(
        len(_SILENT_KEY.as_bytes()),
        33,
        "2: the silent band was measured at a 33-byte key; if this string has"
        " been edited to another length the check below is measuring something"
        " else",
    )
    var got = read_decode(store_encode(silent))
    print("  [case 2] read side saw object_key = '" + got.object_key + "'")
    print("  [case 2] read side saw min_ts_ns  = " + String(got.min_ts_ns))
    print("  [case 2] read side saw max_ts_ns  = " + String(got.max_ts_ns))
    assert_equal(
        got.object_key,
        _SILENT_KEY,
        "2: THE ORIGINAL DEFECT. Pre-fix this was '' and nothing raised",
    )
    assert_equal(
        Int(got.min_ts_ns),
        Int(_MIN_TS),
        "2: pre-fix this was 33 — the object key's LENGTH used as a"
        " nanosecond timestamp",
    )
    assert_equal(
        Int(got.max_ts_ns),
        Int(_MAX_TS),
        "2: pre-fix this was some garbage value: ASCII characters of"
        " the object key reinterpreted as an i64",
    )
    assert_equal(Int(got.row_count), Int(_ROWS), "2: row_count survives")
    assert_equal(Int(got.byte_size), Int(_BYTES), "2: byte_size survives")
    assert_true(got.has_text_sidecar, "2: the sidecar bit survives")

    var back = store_decode(read_encode(b))
    assert_equal(
        back.object_key, _KEY, "2: and the other direction, read -> store"
    )
    assert_equal(
        Int(back.min_ts_ns), Int(_MIN_TS), "2: other direction, pruning key"
    )


# =============================================================================
# CASE 3 — THE GOLDEN VECTOR. 99 pinned bytes.
# =============================================================================
#
# WHY A GOLDEN VECTOR AND NOT ANOTHER ROUND TRIP. `decode(encode(x)) == x` is
# satisfied by any self-consistent codec, including a re-ordered one — that is
# exactly what both sides had, separately, and both suites were green. Only
# bytes fixed OUTSIDE the codec can notice a layout change, so these are written
# down here and compared literally.
# =============================================================================


comptime _GOLDEN_HEX: String = (
    "02a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a50900000000000000"
    "6b2e706172717565740000466dec57d118ff578d65fa57d118"
    "000000000000000000000000000000007310000000000000b9"
    "440000000000000000000000000000000000000000000001"
)
"""THE PINNED ENVELOPE, as hex. 99 bytes: version 2, uuid = 16 x 0xA5,
key = "k.parquet", min_ts = 1788307200000000000, max_ts = 1788307259999999999,
series bounds 0/0, rows = 4211, byte_size = 17593, merge_ops = 0, no merge
inputs, has_text_sidecar = True.

IF A FORMAT CHANGE MAKES THIS FAIL, BUMP THE VERSION AND REGENERATE. Editing
this constant to match new output is how a layout change ships under an
unchanged version byte — which is the entire defect this file exists to prevent
recurring."""


def _hex_nibble(c: UInt8) raises -> Int:
    if c >= UInt8(48) and c <= UInt8(57):
        return Int(c) - 48
    if c >= UInt8(97) and c <= UInt8(102):
        return Int(c) - 87
    raise Error("golden vector: non-hex character in _GOLDEN_HEX")


def _golden() raises -> List[UInt8]:
    var h = _GOLDEN_HEX.as_bytes()
    if len(h) % 2 != 0:
        raise Error("golden vector: odd number of hex digits")
    var g = List[UInt8](capacity=len(h) // 2)
    for i in range(0, len(h), 2):
        g.append(UInt8(_hex_nibble(h[i]) * 16 + _hex_nibble(h[i + 1])))
    return g^


def test_03_the_envelope_matches_the_golden_vector() raises:
    var e = make_log_segment_entry(
        _uuid(UInt8(0xA5)),
        String("k.parquet"),
        _MIN_TS,
        _MAX_TS,
        _ROWS,
        _BYTES,
        True,
    )
    var enc = store_encode(e)
    var gold = _golden()
    assert_equal(
        len(enc),
        len(gold),
        "3: the envelope is 99 bytes for a 9-byte key and no merge inputs"
        " (1 + 16 + 8 + 9 + 56 + 8 + 1). A different length means a field was"
        " added, moved or dropped",
    )
    for i in range(len(gold)):
        assert_equal(
            Int(enc[i]),
            Int(gold[i]),
            "3: envelope byte "
            + String(i)
            + " drifted from the pinned vector. If this is an intentional"
            " format change, BUMP THE VERSION to 3 and regenerate — do not"
            " edit the vector to match, which is how a layout change ships"
            " under an unchanged version byte",
        )

    # The vector decodes back to what built it.
    var got = store_decode(gold)
    assert_equal(got.object_key, String("k.parquet"), "3: golden key")
    assert_equal(Int(got.min_ts_ns), Int(_MIN_TS), "3: golden min_ts")
    assert_equal(Int(got.max_ts_ns), Int(_MAX_TS), "3: golden max_ts")
    assert_equal(Int(got.row_count), Int(_ROWS), "3: golden rows")
    assert_true(got.has_text_sidecar, "3: golden sidecar bit")


def main() raises:
    test_00_the_read_sides_legacy_layout_is_refused_by_name()
    test_01_the_write_sides_legacy_layout_is_refused_too()
    test_02_both_import_paths_are_one_codec()
    test_03_the_envelope_matches_the_golden_vector()
    print("PASS komira_log_index.test_telemetry_codec_agreement (ONE codec,")
    print("     reached by both import paths, byte-identical to a pinned")
    print("     vector; version 1 REFUSED BY NAME in both historical orders)")
