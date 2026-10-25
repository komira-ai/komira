# =============================================================================
# komira_telemetry_store/tests/test_telemetry_keys.mojo
#   THE FALSIFIER for the object-key layout, the layer that makes "discovery by
#   manifest replay, NEVER by listing" possible at all.
# =============================================================================
#
# The day partition is not a naming convention; it is THE INDEX. A reader
# holding [t0,t1] COMPUTES the prefixes it must consider and never asks the
# bucket what exists, which matters because the object store has exactly ONE
# listing primitive, it is single-level, and its two conformers disagree in
# BOTH directions (a nested key is an object on a local-filesystem store and a
# rollup on a cloud one; `common_prefixes` is always empty on the first and
# always populated on the second).
#
# So every case here is about one of three things:
#   * the partition function is CORRECT (a wrong day files a row where its own
#     query will not look);
#   * the key DEPTH is a constant (rule 3 in keys.mojo);
#   * the sidecar's key is DERIVED from the base's, so pairing them needs no
#     listing.
#
# ASSERTIONS ARE ON THE PRODUCED STRING, NOT ON A COUNT. A count-based
# assertion ("3 days") passes for a generator returning the wrong three days.
# HERMETIC: pure arithmetic and string building. No store, no I/O, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_telemetry_store.keys import (
    MAX_TELEMETRY_DAYS_PER_QUERY,
    NS_PER_DAY,
    NS_PER_MS,
    TELEMETRY_DATA_KEY_DEPTH,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_PARTITION_PREFIX_DEPTH,
    TELEMETRY_ROOT,
    civil_from_day_index,
    day_end_ns,
    day_index_from_civil,
    day_index_from_ns,
    day_start_ns,
    day_string_from_day_index,
    day_string_from_ns,
    days_covering,
    telemetry_data_key,
    telemetry_key_depth,
    telemetry_partition_prefix,
    telemetry_text_sidecar_key,
    uuid_hex,
)


def _uuid(fill: UInt8) -> InlineArray[UInt8, 16]:
    return InlineArray[UInt8, 16](fill=fill)


def _uuid_counting() -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8(i)
    return u^


# =============================================================================
# CASE 1 — the partition function lands each timestamp in the RIGHT UTC day.
#
# Hand-computed dates, not a round-trip against the same arithmetic: a
# round-trip of a wrong formula against its own inverse is green.
# =============================================================================


def test_01_day_string_is_the_utc_calendar_day() raises:
    assert_equal(day_string_from_ns(Int64(0)), String("19700101"), "1: epoch")
    # 2026-10-01T00:00:00Z = epoch second 1790812800 (day index 20727),
    # hand-checked: 20727 days * 86400 s.
    var t = Int64(1790812800) * Int64(1_000_000_000)
    assert_equal(day_string_from_ns(t), String("20261001"), "1: 2026-10-01")
    # ...and the last nanosecond of that day is still that day.
    assert_equal(
        day_string_from_ns(t + NS_PER_DAY - Int64(1)),
        String("20261001"),
        "1: 23:59:59.999999999 is STILL the same partition — an exclusive"
        " boundary here would file the last log line of every day into the"
        " next one",
    )
    # ...and one nanosecond later is the next day.
    assert_equal(
        day_string_from_ns(t + NS_PER_DAY),
        String("20261002"),
        "1: midnight rolls the partition",
    )
    # A leap day must exist (2024-02-29 = 1709164800).
    assert_equal(
        day_string_from_ns(Int64(1709164800) * Int64(1_000_000_000)),
        String("20240229"),
        "1: leap day",
    )
    # A pre-epoch timestamp must FLOOR, not truncate toward zero: 1969-12-31.
    assert_equal(
        day_string_from_ns(Int64(-1)),
        String("19691231"),
        "1: a pre-epoch ns must FLOOR to the day BEFORE the epoch. Truncation"
        " toward zero would answer 19700101 and put the row in a partition"
        " whose [min,max] contract it violates",
    )


def test_02_day_arithmetic_round_trips_and_bounds_are_closed() raises:
    var d = day_index_from_civil(2026, 10, 1)
    var c = civil_from_day_index(d)
    assert_equal(c.year, 2026, "2: year")
    assert_equal(c.month, 10, "2: month")
    assert_equal(c.day, 1, "2: day")
    # The day's inclusive bounds must both map back to the same day.
    assert_equal(
        day_string_from_ns(day_start_ns(d)),
        String("20261001"),
        "2: day_start_ns is IN the day",
    )
    assert_equal(
        day_string_from_ns(day_end_ns(d)),
        String("20261001"),
        "2: day_end_ns is IN the day (closed upper bound)",
    )
    assert_equal(
        day_index_from_ns(day_end_ns(d) + Int64(1)),
        d + Int64(1),
        "2: one ns past day_end_ns is the NEXT day",
    )


# =============================================================================
# CASE 3 — days_covering IS the read-path prefix generator. Zero I/O.
# =============================================================================


def test_03_days_covering_enumerates_exactly_the_partitions_touched() raises:
    var t0 = Int64(1790812800) * Int64(1_000_000_000)  # 2026-10-01T00:00:00Z
    var same = days_covering(t0, t0 + Int64(60) * Int64(1_000_000_000))
    assert_equal(len(same), 1, "3: a 60 s window touches ONE partition")
    assert_equal(same[0], String("20261001"), "3: and it is the right one")

    # Across midnight — the case a dashboard hits every night.
    var cross = days_covering(t0 + NS_PER_DAY - Int64(1), t0 + NS_PER_DAY)
    assert_equal(len(cross), 2, "3: 1 ns across midnight touches TWO")
    assert_equal(cross[0], String("20261001"), "3: first partition BY NAME")
    assert_equal(cross[1], String("20261002"), "3: second partition BY NAME")

    # A 30-day retention window: 31 partitions, ascending, no gaps.
    var month = days_covering(t0 - Int64(30) * NS_PER_DAY, t0)
    assert_equal(len(month), 31, "3: 30 d inclusive == 31 day partitions")
    assert_equal(month[0], String("20260901"), "3: oldest partition")
    assert_equal(month[30], String("20261001"), "3: newest partition")
    for i in range(1, len(month)):
        assert_true(
            month[i - 1] < month[i],
            "3: partitions must come back ASCENDING and DISTINCT — a reader"
            " walks them in order and a duplicate would replay a manifest"
            " twice",
        )


def test_04_days_covering_refuses_the_two_ways_it_could_lie() raises:
    var t0 = Int64(1790812800) * Int64(1_000_000_000)
    var inverted = False
    try:
        _ = days_covering(t0, t0 - Int64(1))
    except:
        inverted = True
    assert_true(
        inverted,
        "4: an inverted range must RAISE. Returning zero partitions is"
        " indistinguishable from 'no data in range' — a silent wrong answer",
    )
    var unbounded = False
    try:
        _ = days_covering(
            Int64(0), Int64(MAX_TELEMETRY_DAYS_PER_QUERY + 1) * NS_PER_DAY
        )
    except:
        unbounded = True
    assert_true(
        unbounded,
        "4: a range over the day ceiling must RAISE rather than expand into"
        " that many exact GETs",
    )


# =============================================================================
# CASE 5 — the keys. DEPTH IS A CONSTANT (rule 3).
# =============================================================================


def test_05_the_data_key_is_the_documented_shape_at_the_documented_depth() raises:
    var key = telemetry_data_key(
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_LOGS,
        String("20261001"),
        Int64(1790812800123),
        _uuid_counting(),
    )
    assert_equal(
        key,
        String(
            "telemetry/logs/20261001/data/"
            "00000001790812800123-000102030405060708090a0b0c0d0e0f.parquet"
        ),
        "5: the key is asserted BYTE FOR BYTE. A shape assertion (starts-with,"
        " ends-with) would pass for a key whose <start_ms> was unpadded, and an"
        " unpadded start_ms breaks the time-ordered single-level LIST that is"
        " the recovery path",
    )
    assert_equal(
        telemetry_key_depth(key),
        TELEMETRY_DATA_KEY_DEPTH,
        "5: key DEPTH is a CONSTANT (keys.mojo rule 3). A key one level deeper"
        " changes what a single-level LIST returns, and the two ObjectStore"
        " conformers break in OPPOSITE directions — silently, both of them",
    )
    assert_equal(
        telemetry_key_depth(
            telemetry_partition_prefix(
                TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001")
            )
        ),
        TELEMETRY_PARTITION_PREFIX_DEPTH,
        "5: the partition prefix depth is a constant too",
    )


def test_06_start_ms_prefix_makes_the_basenames_sort_in_time_order() raises:
    var early = telemetry_data_key(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        Int64(9), _uuid(UInt8(255)),
    )
    var late = telemetry_data_key(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        Int64(10), _uuid(UInt8(0)),
    )
    assert_true(
        early < late,
        "6: an EARLIER start_ms must sort BEFORE a later one even when its uuid"
        " sorts after. That is what the 20-digit zero pad buys, and it is what"
        " makes the single-level LIST of `.../data/` a time-ordered recovery"
        " path",
    )


def test_07_a_segment_that_would_change_the_key_depth_is_refused() raises:
    var nested = False
    try:
        _ = telemetry_partition_prefix(
            TELEMETRY_ROOT, String("logs/us"), String("20261001")
        )
    except:
        nested = True
    assert_true(
        nested,
        "7: a dataset segment containing '/' must RAISE. It would add a level"
        " to every key under it, and a two-level layout looks fine on LocalFs"
        " and returns nothing on GCS",
    )
    var empty = False
    try:
        _ = telemetry_partition_prefix(
            TELEMETRY_ROOT, String(""), String("20261001")
        )
    except:
        empty = True
    assert_true(
        empty,
        "7: an empty segment must RAISE — it collapses a level, which is the"
        " same lie about depth in the other direction",
    )


# =============================================================================
# CASE 8 — THE SIDECAR'S KEY IS DERIVED. This is what makes the text split a
# sidecar WITHOUT adding a second manifest or a pairing LIST: the name is
# derivable.
# =============================================================================


def test_08_the_sidecar_key_is_derived_from_the_base_key() raises:
    var base = telemetry_data_key(
        TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        Int64(1790812800123), _uuid_counting(),
    )
    assert_equal(
        telemetry_text_sidecar_key(base),
        String(
            "telemetry/logs/20261001/text/"
            "00000001790812800123-000102030405060708090a0b0c0d0e0f.split"
        ),
        "8: same partition, same basename, different leaf segment and suffix."
        " A reader that has the base key needs NO listing to find the sidecar",
    )
    assert_equal(
        telemetry_key_depth(telemetry_text_sidecar_key(base)),
        TELEMETRY_DATA_KEY_DEPTH,
        "8: the sidecar sits at the SAME depth as its base",
    )


def test_09_a_foreign_key_cannot_be_turned_into_a_sidecar_key() raises:
    var wrong_suffix = False
    try:
        _ = telemetry_text_sidecar_key(
            String("telemetry/logs/20261001/data/000-abc.split")
        )
    except:
        wrong_suffix = True
    assert_true(
        wrong_suffix,
        "9: a key that is not a .parquet base key must RAISE. A derived sidecar"
        " key for an object that does not exist reads back as not-found, and a"
        " not-found on the text path is trivially folded to 'no matches' — a"
        " silent wrong answer, not an error",
    )
    var no_data_segment = False
    try:
        _ = telemetry_text_sidecar_key(
            String("telemetry/logs/20261001/000-abc.parquet")
        )
    except:
        no_data_segment = True
    assert_true(
        no_data_segment,
        "9: a key with no '/data/' parent segment must RAISE",
    )
    # THE STRUCTURAL-vs-SUBSTRING CASE, AND IT IS BUILT TO DISCRIMINATE.
    # A naive `data_key.find("/data/")` takes the FIRST occurrence. Give the
    # DATASET the name `data` and the first `/data/` is the dataset segment, not
    # the leaf's parent — so a first-occurrence derivation emits
    # `x/text/20261001/data/...`: the dataset renamed, the real segment left
    # alone, a sidecar under a prefix nothing writes to and nothing lists.
    # (A ROOT named `data` does NOT discriminate: `data/...` has no leading
    # slash, so `/data/` still first matches the right segment. Measured.)
    var tricky = telemetry_data_key(
        String("x"), String("data"), String("20261001"),
        Int64(7), _uuid(UInt8(0)),
    )
    var derived = telemetry_text_sidecar_key(tricky)
    assert_true(
        derived.find(String("x/data/20261001/text/")) == 0,
        "9: the DATASET segment 'data' must survive and only the"
        " SECOND-TO-LAST segment may be rewritten. A first-occurrence"
        " derivation emits 'x/text/20261001/data/...' — the wrong segment"
        " rewritten, in both directions. Got: " + derived,
    )
    assert_false(
        derived.find(String("x/text/")) == 0,
        "9: ...and specifically NOT the dataset segment",
    )


def test_10_uuid_hex_is_fixed_width_lowercase() raises:
    assert_equal(
        uuid_hex(_uuid_counting()),
        String("000102030405060708090a0b0c0d0e0f"),
        "10: 32 lowercase hex chars, byte order preserved",
    )
    assert_equal(
        uuid_hex(_uuid(UInt8(255))).byte_length(),
        32,
        "10: FIXED width — a variable-width uuid would break the"
        " lexicographic time order the <start_ms> prefix establishes",
    )


def main() raises:
    test_01_day_string_is_the_utc_calendar_day()
    test_02_day_arithmetic_round_trips_and_bounds_are_closed()
    test_03_days_covering_enumerates_exactly_the_partitions_touched()
    test_04_days_covering_refuses_the_two_ways_it_could_lie()
    test_05_the_data_key_is_the_documented_shape_at_the_documented_depth()
    test_06_start_ms_prefix_makes_the_basenames_sort_in_time_order()
    test_07_a_segment_that_would_change_the_key_depth_is_refused()
    test_08_the_sidecar_key_is_derived_from_the_base_key()
    test_09_a_foreign_key_cannot_be_turned_into_a_sidecar_key()
    test_10_uuid_hex_is_fixed_width_lowercase()
    print("PASS komira_telemetry_store.test_telemetry_keys (the UTC day is in")
    print("     the key and is COMPUTED, not discovered; key depth is a")
    print("     constant; and the text sidecar's key is DERIVED from the base's")
    print("     — so pairing them needs no listing)")
