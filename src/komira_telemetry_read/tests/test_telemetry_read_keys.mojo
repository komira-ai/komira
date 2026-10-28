# =============================================================================
# komira_telemetry_read/tests/test_telemetry_read_keys.mojo
#   The writer-side derivations the reader is built on, pinned from the reader's
#   point of view: the day partitions a range touches, the catalog entry's time
#   range, and the sidecar key.
# =============================================================================
#
# The reader owns none of these: the key layout and the entry codec live in
# `komira_telemetry_store`, and the scan planner imports them. These cases fail
# if the writer's derivation moves in a way that would make a reader compute
# the wrong prefix or prune the wrong segment.
#
# What each case would catch if it were wrong:
#   1   the day arithmetic: a window that spans midnight reading ONE partition,
#       a pre-epoch timestamp truncating toward zero into the wrong day.
#   2   the refusals: an inverted or absurd range answered with a partial result.
#   3   the entry codec: a time range that decodes wrong, which prunes a live
#       segment out of every query, silently and forever.
#   9   the sidecar key: derived from the data key (same basename, `text` for
#       `data`, `.textidx` for `.parquet`), and refused for a foreign key.
#
# HERMETIC: pure arithmetic and codecs, no store, no clock.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_telemetry_store.keys import (
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    day_string_from_ns,
    days_covering,
    telemetry_data_key,
    telemetry_text_sidecar_key,
    uuid_hex,
)
from komira_telemetry_store.segment_entry import (
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    make_raw_segment_entry,
)

# 2026-09-15T00:00:00Z in nanoseconds.
comptime _SEP15: Int64 = 1789430400_000_000_000
comptime _HOUR: Int64 = 3_600_000_000_000
comptime _DAY: Int64 = 86_400_000_000_000


def _uuid16(seed: Int) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 37 + i * 11) % 256)
    return u^


# =============================================================================
# CASE 1 - the day arithmetic. A window is turned into partitions with NO I/O.
# =============================================================================
def test_01_day_arithmetic_computes_partitions_without_io() raises:
    # The epoch itself and a known date, to pin the civil-from-days conversion.
    assert_equal(
        day_string_from_ns(Int64(0)), String("19700101"), "1: the epoch day"
    )
    assert_equal(
        day_string_from_ns(_SEP15), String("20260915"), "1: the fixture day"
    )
    # A LEAP DAY: the era arithmetic must handle the 4/100/400 rules.
    # 2028-02-29T00:00:00Z.
    assert_equal(
        day_string_from_ns(Int64(1835395200_000_000_000)),
        String("20280229"),
        "1: a leap day resolves, so the era arithmetic handles the 4/100/400"
        " rules",
    )
    # A century that is NOT a leap year: the day after 2100-02-28 is 03-01.
    assert_equal(
        day_string_from_ns(Int64(4107456000_000_000_000)),
        String("21000228"),
        "1: 2100-02-28 resolves",
    )
    assert_equal(
        day_string_from_ns(Int64(4107542400_000_000_000)),
        String("21000301"),
        "1: 2100 is not a leap year, so the next day is March 1",
    )
    # BEFORE THE EPOCH. A corrupt row, an unset field, or milliseconds mistaken
    # for nanoseconds all land here, and truncation toward zero would put -1ns
    # in 19700101 and MISS the object that holds it.
    assert_equal(
        day_string_from_ns(Int64(-1)),
        String("19691231"),
        "1: a pre-epoch timestamp FLOORS to the earlier day",
    )

    # A dashboard's 15-minute window is ONE partition.
    var quarter = days_covering(_SEP15 + _HOUR, _SEP15 + _HOUR + _HOUR // 4)
    assert_equal(len(quarter), 1, "1: a 15-minute window is ONE day partition")

    # Across midnight: TWO, and no more.
    var midnight = days_covering(_SEP15 - _HOUR, _SEP15 + _HOUR)
    assert_equal(len(midnight), 2, "1: a midnight straddle is TWO partitions")
    assert_equal(midnight[0], String("20260914"), "1: ascending, earliest first")
    assert_equal(midnight[1], String("20260915"), "1: ascending, latest last")

    # A 30-day sweep: 31 partitions, INCLUSIVE at both ends.
    var month = days_covering(_SEP15 - Int64(30) * _DAY, _SEP15)
    assert_equal(
        len(month), 31, "1: a 30-day range is 31 INCLUSIVE day partitions"
    )


# =============================================================================
# CASE 2 - the refusals. A partial answer is worse than an error here.
# =============================================================================
def test_02_absurd_ranges_are_refused_not_clamped() raises:
    var inverted_raised = False
    try:
        _ = days_covering(_SEP15, _SEP15 - _DAY)
    except:
        inverted_raised = True
    assert_true(
        inverted_raised,
        "2: an INVERTED range raises: answering it with an empty list is"
        " indistinguishable from 'no telemetry in that window'",
    )

    var too_wide_raised = False
    try:
        _ = days_covering(Int64(0), _SEP15)
    except:
        too_wide_raised = True
    assert_true(
        too_wide_raised,
        "2: a 56-year range is REFUSED rather than clamped: a clamp returns a"
        " silently partial answer",
    )

    # And the boundary is inclusive-correct: exactly one instant is one day.
    var instant = days_covering(_SEP15, _SEP15)
    assert_equal(len(instant), 1, "2: [t,t] is ONE partition, not zero")


# =============================================================================
# CASE 3 - the catalog entry codec. Round-trip, and every corruption REFUSED.
# =============================================================================
def test_03_segment_entry_round_trips_and_refuses_corruption() raises:
    var e = make_raw_segment_entry(
        String("telemetry/logs/20260915/data/x.parquet"),
        _SEP15,
        _SEP15 + _HOUR,
        Int64(4242),
        Int64(99),
        _uuid16(7),
    )
    var got = decode_telemetry_segment_entry(encode_telemetry_segment_entry(e))
    assert_equal(got.object_key, e.object_key, "3: the object key round-trips")
    assert_equal(got.min_ts_ns, _SEP15, "3: min_ts_ns round-trips")
    assert_equal(got.max_ts_ns, _SEP15 + _HOUR, "3: max_ts_ns round-trips")
    assert_equal(got.row_count, Int64(4242), "3: row_count round-trips")
    assert_false(got.is_merged(), "3: a raw entry is not merged")

    # THE OVERLAP TEST IS THE PRUNE, so it is asserted directly.
    assert_true(
        got.overlaps_time(_SEP15 + _HOUR, _SEP15 + _HOUR),
        "3: max_ts is INCLUSIVE: a probe at the upper bound must not prune the"
        " segment holding it",
    )
    assert_false(
        got.overlaps_time(_SEP15 + _HOUR + Int64(1), _SEP15 + _DAY),
        "3: a range starting one ns after max_ts prunes",
    )
    assert_false(
        got.overlaps_time(_SEP15 - _DAY, _SEP15 - Int64(1)),
        "3: a range ending one ns before min_ts prunes",
    )

    # Truncation must RAISE, not decode to a plausible entry.
    var enc = encode_telemetry_segment_entry(e)
    var truncated = List[UInt8]()
    for i in range(len(enc) - 9):
        truncated.append(enc[i])
    var trunc_raised = False
    try:
        _ = decode_telemetry_segment_entry(truncated)
    except:
        trunc_raised = True
    assert_true(
        trunc_raised,
        "3: a TRUNCATED body raises: a leniently decoded entry gets a"
        " plausible-but-wrong time range and prunes itself out of every query",
    )

    # An unknown envelope version must RAISE, not best-effort.
    var wrong_version = List[UInt8]()
    for i in range(len(enc)):
        wrong_version.append(enc[i])
    wrong_version[0] = UInt8(99)
    var ver_raised = False
    try:
        _ = decode_telemetry_segment_entry(wrong_version)
    except:
        ver_raised = True
    assert_true(ver_raised, "3: an unknown envelope version is REFUSED")


# =============================================================================
# CASE 9 - the sidecar key is DERIVED from the data key, never listed.
# =============================================================================
def test_09_the_text_sidecar_key_is_derivable_from_the_data_key() raises:
    var u = _uuid16(5)
    var data = telemetry_data_key(
        String(TELEMETRY_ROOT),
        String(TELEMETRY_DATASET_LOGS),
        String("20260915"),
        Int64(42),
        u,
    )
    var side = telemetry_text_sidecar_key(data)
    assert_equal(
        side,
        String("telemetry/logs/20260915/text/00000000000000000042-")
        + uuid_hex(u)
        + String(".textidx"),
        "9: same basename, `text` for `data`, `.textidx` for `.parquet`: no"
        " listing is needed to pair them",
    )
    var bad_raised = False
    try:
        _ = telemetry_text_sidecar_key(String("not/a/telemetry/key"))
    except:
        bad_raised = True
    assert_true(
        bad_raised,
        "9: a non-data key RAISES rather than returning a plausible-but-wrong"
        " key that would GET an object that does not exist",
    )


def main() raises:
    test_01_day_arithmetic_computes_partitions_without_io()
    test_02_absurd_ranges_are_refused_not_clamped()
    test_03_segment_entry_round_trips_and_refuses_corruption()
    test_09_the_text_sidecar_key_is_derivable_from_the_data_key()
    print("test_telemetry_read_keys: OK")
