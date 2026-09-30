# =============================================================================
# test_select_optimal_strategy
# =============================================================================
#
# Type-only strategy detection: a single Bool/Int8/Int16/UInt8/UInt16 key
# returns PerfectHash unconditionally; everything else returns Columnar.
#
# Stats-driven detection for Int32+ keys is not implemented yet; those keys
# return Columnar here.
# =============================================================================

from std.testing import assert_equal

from komira_core.arrow.arrow_types import ArrowType
from komira_core.agg_strategy import (
    select_optimal_strategy_type_only,
    AggStrategy,
    AGG_STRATEGY_UNGROUPED,
    AGG_STRATEGY_COLUMNAR,
    AGG_STRATEGY_PERFECT_HASH,
    AGG_STRATEGY_PERFECT_HASH_COMPOSITE,
    KEY_DOMAIN_INT,
    KEY_DOMAIN_DICT,
    KeyDomain,
)


# -----------------------------------------------------------------------------
# Empty / Ungrouped
# -----------------------------------------------------------------------------


def test_empty_keys_returns_ungrouped() raises:
    """No GROUP BY columns → Ungrouped."""
    var keys = List[ArrowType]()
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_UNGROUPED)


# -----------------------------------------------------------------------------
# Pass 1 — single-key type-only PerfectHash detection
# -----------------------------------------------------------------------------


def test_bool_returns_perfect_hash() raises:
    """single Bool key → PH(domain=2, offset=0)."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.BOOL)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH)
    assert_equal(s.domain_size, 2)
    assert_equal(s.key_offset, 0)


def test_int8_returns_perfect_hash() raises:
    """single Int8 key → PH(domain=256, offset=128).

    Offset 128 maps i8::MIN=-128 to index 0 ([0,255]).
    """
    var keys = List[ArrowType]()
    keys.append(ArrowType.INT8)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH)
    assert_equal(s.domain_size, 256)
    assert_equal(s.key_offset, 128)


def test_uint8_returns_perfect_hash() raises:
    """single UInt8 key → PH(domain=256, offset=0)."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.UINT8)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH)
    assert_equal(s.domain_size, 256)
    assert_equal(s.key_offset, 0)


def test_int16_returns_perfect_hash() raises:
    """single Int16 key → PH(domain=65536, offset=32768).

    Offset 32768 maps i16::MIN=-32768 to index 0 ([0,65535]).
    """
    var keys = List[ArrowType]()
    keys.append(ArrowType.INT16)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH)
    assert_equal(s.domain_size, 65536)
    assert_equal(s.key_offset, 32768)


def test_uint16_returns_perfect_hash() raises:
    """single UInt16 key → PH(domain=65536, offset=0)."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.UINT16)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH)
    assert_equal(s.domain_size, 65536)
    assert_equal(s.key_offset, 0)


# -----------------------------------------------------------------------------
# Fall-through to Columnar — stats-driven territory
# -----------------------------------------------------------------------------


def test_int32_falls_through_to_columnar() raises:
    """Int32 falls through Pass 1; a stats-driven pass would upgrade to PH if
    the domain fits. Without stats it returns Columnar."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.INT32)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_int64_falls_through_to_columnar() raises:
    """Int64 returns Columnar (no stats-driven pass)."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.INT64)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_uint32_falls_through_to_columnar() raises:
    var keys = List[ArrowType]()
    keys.append(ArrowType.UINT32)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_uint64_falls_through_to_columnar() raises:
    var keys = List[ArrowType]()
    keys.append(ArrowType.UINT64)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_string_falls_through_to_columnar() raises:
    """non-int types bypass both passes → Columnar."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.STRING)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_float64_falls_through_to_columnar() raises:
    var keys = List[ArrowType]()
    keys.append(ArrowType.FLOAT64)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


# -----------------------------------------------------------------------------
# Multi-key — composite path
# -----------------------------------------------------------------------------


def test_multi_key_int8_falls_through_to_columnar() raises:
    """Pass 1 only fires for `key_columns.len() == 1`. Multi-key with small
    domains needs stats + composite logic; it returns Columnar.
    """
    var keys = List[ArrowType]()
    keys.append(ArrowType.INT8)
    keys.append(ArrowType.INT8)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


def test_multi_key_bool_int8_falls_through_to_columnar() raises:
    """Multi-key with mixed small-domain types → Columnar."""
    var keys = List[ArrowType]()
    keys.append(ArrowType.BOOL)
    keys.append(ArrowType.INT8)
    var s = select_optimal_strategy_type_only(keys)
    assert_equal(s.tag, AGG_STRATEGY_COLUMNAR)


# -----------------------------------------------------------------------------
# AggStrategy / KeyDomain constructor sanity checks
# -----------------------------------------------------------------------------


def test_keydomain_int_constructor() raises:
    """KeyDomain.int_domain(min, range, stride) sets tag=INT and zeroes Dict
    fields."""
    var kd = KeyDomain.int_domain(-100, 200, 4)
    assert_equal(kd.tag, KEY_DOMAIN_INT)
    assert_equal(kd.min, -100)
    assert_equal(kd.range, 200)
    assert_equal(kd.stride, 4)
    assert_equal(kd.dict_size, 0)


def test_keydomain_dict_constructor() raises:
    """KeyDomain.dict_domain(dict_size, stride) sets tag=DICT and zeroes
    Int fields."""
    var kd = KeyDomain.dict_domain(50, 1)
    assert_equal(kd.tag, KEY_DOMAIN_DICT)
    assert_equal(kd.dict_size, 50)
    assert_equal(kd.stride, 1)
    assert_equal(kd.min, 0)
    assert_equal(kd.range, 0)


def test_aggstrategy_perfect_hash_composite_constructor() raises:
    """AggStrategy.perfect_hash_composite(...) carries domain + key list.
    For the Dict composite path."""
    var keys = List[KeyDomain]()
    keys.append(KeyDomain.int_domain(0, 16, 16))
    keys.append(KeyDomain.int_domain(0, 16, 1))
    var s = AggStrategy.perfect_hash_composite(256, keys^)
    assert_equal(s.tag, AGG_STRATEGY_PERFECT_HASH_COMPOSITE)
    assert_equal(s.domain_size, 256)
    assert_equal(len(s.keys), 2)
    assert_equal(s.keys[0].stride, 16)
    assert_equal(s.keys[1].stride, 1)


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    test_empty_keys_returns_ungrouped()
    test_bool_returns_perfect_hash()
    test_int8_returns_perfect_hash()
    test_uint8_returns_perfect_hash()
    test_int16_returns_perfect_hash()
    test_uint16_returns_perfect_hash()
    test_int32_falls_through_to_columnar()
    test_int64_falls_through_to_columnar()
    test_uint32_falls_through_to_columnar()
    test_uint64_falls_through_to_columnar()
    test_string_falls_through_to_columnar()
    test_float64_falls_through_to_columnar()
    test_multi_key_int8_falls_through_to_columnar()
    test_multi_key_bool_int8_falls_through_to_columnar()
    test_keydomain_int_constructor()
    test_keydomain_dict_constructor()
    test_aggstrategy_perfect_hash_composite_constructor()
    print("test_select_optimal_strategy: all 17 tests OK")
