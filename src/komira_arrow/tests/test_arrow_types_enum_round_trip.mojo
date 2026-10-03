# =============================================================================
# ArrowType enum + format-string round-trip tests
# =============================================================================
#
# Verifies that every time / duration / interval / union / decimal256 slot:
#   1. Has a stable type_id distinct from all other slots.
#   2. Emits the correct Arrow C Data Interface format string per the spec
#      (https://arrow.apache.org/docs/format/CDataInterface.html).
#   3. Round-trips through parse_format_string() back to the same slot
#      (emit -> parse -> emit byte-identical).
#
# Type-system only: Column variants and C-Data codepaths are covered by the
# other arrow tests.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import (
    ArrowType,
    decimal_format_string,
    decimal256_format_string,
    timestamp_format_string,
    union_format_string,
    parse_format_string,
)


# =============================================================================
# Time / duration / interval / union slots — type_id distinctness
# =============================================================================


def test_new_enum_slots_have_distinct_ids() raises:
    """The 14 time / duration / interval / union / decimal256 slots all have
    distinct type_ids from each other and from every classic slot."""
    var slots: List[ArrowType] = [
        ArrowType.DECIMAL256,
        ArrowType.TIME32_S,
        ArrowType.TIME32_MS,
        ArrowType.TIME64_US,
        ArrowType.TIME64_NS,
        ArrowType.DURATION_S,
        ArrowType.DURATION_MS,
        ArrowType.DURATION_US,
        ArrowType.DURATION_NS,
        ArrowType.INTERVAL_YEAR_MONTH,
        ArrowType.INTERVAL_DAY_TIME,
        ArrowType.INTERVAL_MONTH_DAY_NANO,
        ArrowType.UNION_SPARSE,
        ArrowType.UNION_DENSE,
    ]
    # Each slot's type_id is unique within the list.
    for i in range(len(slots)):
        for j in range(i + 1, len(slots)):
            assert_true(slots[i].type_id != slots[j].type_id)
    # Each new slot is distinct from every pre-existing slot.
    var prior: List[ArrowType] = [
        ArrowType.NULL,
        ArrowType.BOOL,
        ArrowType.INT8, ArrowType.INT16, ArrowType.INT32, ArrowType.INT64,
        ArrowType.UINT8, ArrowType.UINT16, ArrowType.UINT32, ArrowType.UINT64,
        ArrowType.FLOAT16, ArrowType.FLOAT32, ArrowType.FLOAT64,
        ArrowType.STRING, ArrowType.BINARY,
        ArrowType.LARGE_STRING, ArrowType.LARGE_BINARY,
        ArrowType.DATE32, ArrowType.DATE64,
        ArrowType.TIMESTAMP, ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_NS,
        ArrowType.DECIMAL128,
        ArrowType.DICTIONARY, ArrowType.LIST, ArrowType.STRUCT, ArrowType.MAP,
    ]
    for i in range(len(slots)):
        for j in range(len(prior)):
            assert_true(slots[i].type_id != prior[j].type_id)


# =============================================================================
# Time / duration / interval / union slots — write_to (human-readable name)
# =============================================================================


def test_new_enum_slots_write_to() raises:
    """write_to() produces a human-readable name for every one of those slots."""
    assert_equal(String(ArrowType.DECIMAL256), "decimal256")
    assert_equal(String(ArrowType.TIME32_S), "time32[s]")
    assert_equal(String(ArrowType.TIME32_MS), "time32[ms]")
    assert_equal(String(ArrowType.TIME64_US), "time64[us]")
    assert_equal(String(ArrowType.TIME64_NS), "time64[ns]")
    assert_equal(String(ArrowType.DURATION_S), "duration[s]")
    assert_equal(String(ArrowType.DURATION_MS), "duration[ms]")
    assert_equal(String(ArrowType.DURATION_US), "duration[us]")
    assert_equal(String(ArrowType.DURATION_NS), "duration[ns]")
    assert_equal(String(ArrowType.INTERVAL_YEAR_MONTH), "interval[year_month]")
    assert_equal(String(ArrowType.INTERVAL_DAY_TIME), "interval[day_time]")
    assert_equal(
        String(ArrowType.INTERVAL_MONTH_DAY_NANO), "interval[month_day_nano]"
    )
    assert_equal(String(ArrowType.UNION_SPARSE), "union[sparse]")
    assert_equal(String(ArrowType.UNION_DENSE), "union[dense]")


# =============================================================================
# Query helpers — is_time / is_duration / is_interval / is_union
# =============================================================================


def test_is_time() raises:
    """is_time() recognizes Time32 and Time64 variants only."""
    assert_true(ArrowType.TIME32_S.is_time())
    assert_true(ArrowType.TIME32_MS.is_time())
    assert_true(ArrowType.TIME64_US.is_time())
    assert_true(ArrowType.TIME64_NS.is_time())
    assert_false(ArrowType.TIMESTAMP_S.is_time())
    assert_false(ArrowType.DURATION_S.is_time())
    assert_false(ArrowType.DATE32.is_time())
    assert_false(ArrowType.INT64.is_time())


def test_is_duration() raises:
    """is_duration() recognizes Duration variants only."""
    assert_true(ArrowType.DURATION_S.is_duration())
    assert_true(ArrowType.DURATION_MS.is_duration())
    assert_true(ArrowType.DURATION_US.is_duration())
    assert_true(ArrowType.DURATION_NS.is_duration())
    assert_false(ArrowType.TIMESTAMP_S.is_duration())
    assert_false(ArrowType.TIME32_S.is_duration())


def test_is_interval() raises:
    """is_interval() recognizes all three Interval sub-variants."""
    assert_true(ArrowType.INTERVAL_YEAR_MONTH.is_interval())
    assert_true(ArrowType.INTERVAL_DAY_TIME.is_interval())
    assert_true(ArrowType.INTERVAL_MONTH_DAY_NANO.is_interval())
    assert_false(ArrowType.DURATION_S.is_interval())
    assert_false(ArrowType.TIMESTAMP_S.is_interval())


def test_is_union() raises:
    """is_union() recognizes sparse and dense Union types only."""
    assert_true(ArrowType.UNION_SPARSE.is_union())
    assert_true(ArrowType.UNION_DENSE.is_union())
    assert_false(ArrowType.STRUCT.is_union())
    assert_false(ArrowType.LIST.is_union())


def test_is_temporal_extended() raises:
    """is_temporal() now covers Time, Duration, and Interval in addition to
    Date and Timestamp."""
    assert_true(ArrowType.TIME32_S.is_temporal())
    assert_true(ArrowType.TIME64_NS.is_temporal())
    assert_true(ArrowType.DURATION_S.is_temporal())
    assert_true(ArrowType.DURATION_NS.is_temporal())
    assert_true(ArrowType.INTERVAL_YEAR_MONTH.is_temporal())
    assert_true(ArrowType.INTERVAL_DAY_TIME.is_temporal())
    assert_true(ArrowType.INTERVAL_MONTH_DAY_NANO.is_temporal())
    # Previously-supported temporals still report True.
    assert_true(ArrowType.DATE32.is_temporal())
    assert_true(ArrowType.TIMESTAMP_NS.is_temporal())
    # Non-temporal slots still report False.
    assert_false(ArrowType.UNION_SPARSE.is_temporal())
    assert_false(ArrowType.DECIMAL256.is_temporal())


# =============================================================================
# Format-string emission — time / duration / interval / union / decimal256
# =============================================================================


def test_format_string_time32_time64() raises:
    """Time32 / Time64 emit Arrow-spec format strings 'tts', 'ttm', 'ttu',
    'ttn' (verified against arrow.apache.org/docs/format/CDataInterface.html)."""
    assert_equal(ArrowType.TIME32_S.format_string(), "tts")
    assert_equal(ArrowType.TIME32_MS.format_string(), "ttm")
    assert_equal(ArrowType.TIME64_US.format_string(), "ttu")
    assert_equal(ArrowType.TIME64_NS.format_string(), "ttn")


def test_format_string_duration() raises:
    """Duration emits 'tDs', 'tDm', 'tDu', 'tDn' (spec)."""
    assert_equal(ArrowType.DURATION_S.format_string(), "tDs")
    assert_equal(ArrowType.DURATION_MS.format_string(), "tDm")
    assert_equal(ArrowType.DURATION_US.format_string(), "tDu")
    assert_equal(ArrowType.DURATION_NS.format_string(), "tDn")


def test_format_string_interval() raises:
    """Interval emits 'tiM' (year-month), 'tiD' (day-time), 'tin'
    (month-day-nano) — spec."""
    assert_equal(ArrowType.INTERVAL_YEAR_MONTH.format_string(), "tiM")
    assert_equal(ArrowType.INTERVAL_DAY_TIME.format_string(), "tiD")
    assert_equal(ArrowType.INTERVAL_MONTH_DAY_NANO.format_string(), "tin")


def test_format_string_union_placeholders() raises:
    """Union emits the prefix placeholder; full type-ids list is appended by
    union_format_string()."""
    assert_equal(ArrowType.UNION_SPARSE.format_string(), "+us:")
    assert_equal(ArrowType.UNION_DENSE.format_string(), "+ud:")


def test_decimal256_format_string_helper() raises:
    """decimal256_format_string() emits 'd:P,S,256' per spec."""
    assert_equal(decimal256_format_string(38, 2), "d:38,2,256")
    assert_equal(decimal256_format_string(76, 0), "d:76,0,256")
    assert_equal(decimal256_format_string(50, 10), "d:50,10,256")


def test_union_format_string_helper() raises:
    """union_format_string() emits '+us:I,J,...' or '+ud:I,J,...' per spec."""
    var type_ids: List[Int] = [0, 1, 2]
    assert_equal(
        union_format_string(ArrowType.UNION_SPARSE, type_ids), "+us:0,1,2"
    )
    assert_equal(
        union_format_string(ArrowType.UNION_DENSE, type_ids), "+ud:0,1,2"
    )
    var single: List[Int] = [5]
    assert_equal(
        union_format_string(ArrowType.UNION_SPARSE, single), "+us:5"
    )
    var empty: List[Int] = []
    assert_equal(union_format_string(ArrowType.UNION_SPARSE, empty), "+us:")


# =============================================================================
# Round-trip — emit -> parse -> emit byte-identical
# =============================================================================


def _round_trip(at: ArrowType) raises:
    """Parse `at.format_string()` and assert the parser returns the same
    ArrowType slot, then re-emit the format string and assert byte-identical."""
    var s0 = at.format_string()
    var parsed = parse_format_string(s0)
    assert_true(parsed == at)
    var s1 = parsed.format_string()
    assert_equal(s0, s1)


def test_round_trip_phase_a_slots() raises:
    """Every time / duration / interval / union / decimal256 slot survives emit -> parse -> emit byte-identical."""
    _round_trip(ArrowType.DECIMAL256)
    _round_trip(ArrowType.TIME32_S)
    _round_trip(ArrowType.TIME32_MS)
    _round_trip(ArrowType.TIME64_US)
    _round_trip(ArrowType.TIME64_NS)
    _round_trip(ArrowType.DURATION_S)
    _round_trip(ArrowType.DURATION_MS)
    _round_trip(ArrowType.DURATION_US)
    _round_trip(ArrowType.DURATION_NS)
    _round_trip(ArrowType.INTERVAL_YEAR_MONTH)
    _round_trip(ArrowType.INTERVAL_DAY_TIME)
    _round_trip(ArrowType.INTERVAL_MONTH_DAY_NANO)
    _round_trip(ArrowType.UNION_SPARSE)
    _round_trip(ArrowType.UNION_DENSE)


def test_round_trip_pre_existing_slots() raises:
    """The parser must also round-trip every classic slot (regression guard
    against parser-vs-emitter drift)."""
    _round_trip(ArrowType.NULL)
    _round_trip(ArrowType.BOOL)
    _round_trip(ArrowType.INT8)
    _round_trip(ArrowType.INT16)
    _round_trip(ArrowType.INT32)
    _round_trip(ArrowType.INT64)
    _round_trip(ArrowType.UINT8)
    _round_trip(ArrowType.UINT16)
    _round_trip(ArrowType.UINT32)
    _round_trip(ArrowType.UINT64)
    _round_trip(ArrowType.FLOAT16)
    _round_trip(ArrowType.FLOAT32)
    _round_trip(ArrowType.FLOAT64)
    _round_trip(ArrowType.STRING)
    _round_trip(ArrowType.LARGE_STRING)
    _round_trip(ArrowType.BINARY)
    _round_trip(ArrowType.LARGE_BINARY)
    _round_trip(ArrowType.DATE32)
    _round_trip(ArrowType.DATE64)
    # Note: ArrowType.TIMESTAMP is legacy (emits "tsu:" — same as
    # TIMESTAMP_US); parse_format_string disambiguates to TIMESTAMP_US.
    _round_trip(ArrowType.TIMESTAMP_S)
    _round_trip(ArrowType.TIMESTAMP_MS)
    _round_trip(ArrowType.TIMESTAMP_US)
    _round_trip(ArrowType.TIMESTAMP_NS)
    _round_trip(ArrowType.LIST)
    _round_trip(ArrowType.STRUCT)
    _round_trip(ArrowType.MAP)


def test_round_trip_decimal128_parameterized() raises:
    """Decimal128 with explicit precision/scale round-trips through
    decimal_format_string() -> parse_format_string(): parser returns
    DECIMAL128 (precision/scale live on the Field, not the type tag)."""
    var s = decimal_format_string(18, 6)
    assert_equal(s, "d:18,6")
    var parsed = parse_format_string(s)
    assert_true(parsed == ArrowType.DECIMAL128)


def test_round_trip_decimal256_parameterized() raises:
    """Decimal256 with explicit precision/scale round-trips: emit 'd:38,2,256'
    -> parse -> DECIMAL256."""
    var s = decimal256_format_string(38, 2)
    assert_equal(s, "d:38,2,256")
    var parsed = parse_format_string(s)
    assert_true(parsed == ArrowType.DECIMAL256)
    # And the inverse path: the discriminator-level format_string() of
    # DECIMAL256 also parses back to DECIMAL256.
    var s2 = ArrowType.DECIMAL256.format_string()  # "d:76,0,256"
    assert_true(parse_format_string(s2) == ArrowType.DECIMAL256)


def test_round_trip_timestamp_with_timezone() raises:
    """Timestamp with timezone parses to the right unit slot (the timezone
    itself is Field plumbing; the type tag is a unit discriminator only)."""
    var s = timestamp_format_string("u", "UTC")
    assert_equal(s, "tsu:UTC")
    assert_true(parse_format_string(s) == ArrowType.TIMESTAMP_US)

    var s_ny = timestamp_format_string("n", "America/New_York")
    assert_equal(s_ny, "tsn:America/New_York")
    assert_true(parse_format_string(s_ny) == ArrowType.TIMESTAMP_NS)


def test_round_trip_union_parameterized() raises:
    """Sparse and dense union with explicit type-ids parse to the right
    Union mode slot (the type-ids list is Field plumbing; the type tag is a
    mode discriminator only)."""
    var sparse_ids: List[Int] = [0, 1, 2]
    var s_sp = union_format_string(ArrowType.UNION_SPARSE, sparse_ids)
    assert_equal(s_sp, "+us:0,1,2")
    assert_true(parse_format_string(s_sp) == ArrowType.UNION_SPARSE)

    var dense_ids: List[Int] = [5, 6]
    var s_dn = union_format_string(ArrowType.UNION_DENSE, dense_ids)
    assert_equal(s_dn, "+ud:5,6")
    assert_true(parse_format_string(s_dn) == ArrowType.UNION_DENSE)


# =============================================================================
# Parser — unrecognized inputs
# =============================================================================


def test_parse_unrecognized_returns_null() raises:
    """Unknown / malformed format strings parse to ArrowType.NULL."""
    assert_true(parse_format_string("") == ArrowType.NULL)
    assert_true(parse_format_string("xyz") == ArrowType.NULL)
    assert_true(parse_format_string("t") == ArrowType.NULL)
    assert_true(parse_format_string("+x") == ArrowType.NULL)
    assert_true(parse_format_string("txX") == ArrowType.NULL)
    # '+u' without a sparse/dense discriminator.
    assert_true(parse_format_string("+u") == ArrowType.NULL)
    assert_true(parse_format_string("+ux") == ArrowType.NULL)


# =============================================================================
# from_dtype — mappings for the non-DType slots
# =============================================================================


def test_from_dtype_unchanged() raises:
    """The time / duration / interval slots do NOT alter DType -> ArrowType
    mappings (they are NOT numeric Mojo DTypes — Time32, Duration, etc. ride
    on primitive int storage and surface as ArrowType, not DType)."""
    assert_true(ArrowType.from_dtype(DType.int32) == ArrowType.INT32)
    assert_true(ArrowType.from_dtype(DType.int64) == ArrowType.INT64)
    assert_true(ArrowType.from_dtype(DType.float64) == ArrowType.FLOAT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
