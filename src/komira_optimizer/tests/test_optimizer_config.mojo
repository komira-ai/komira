# =============================================================================
# test_optimizer_config -- the defaults and fallback rules of OptimizerConfig
# =============================================================================
#
# Every default is pinned here, because a changed default compiles and runs
# without any error. The two clamp methods keep the rule that a non-positive
# value means the default, so neither accessor returns zero or a negative
# value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_optimizer.optimizer_config import (
    OptimizerConfig,
    AGG_INMEM_MAX_ROWS_DEFAULT,
    FACT_STREAM_PROTECT_ROWS_DEFAULT,
)


def test_defaults_are_the_unset_behaviour() raises:
    """Catches a changed default: the agg-CSE gate and cheap-key pre-grouping
    ON, both scan-dedup disables OFF, the two row thresholds at 2,000,000 and
    4,000,000, the SEMI/ANTI reducer pushdown ON and eager aggregation ON."""
    var c = OptimizerConfig()
    assert_true(c.agg_cse_gate)
    assert_true(c.agg_cse_cheapkey)
    assert_false(c.disable_scan_dedup)
    assert_false(c.disable_scan_dedup_for_agg)
    assert_equal(c.fact_stream_protect_rows, 2_000_000)
    assert_equal(c.agg_inmem_max_rows, 4_000_000)
    assert_equal(FACT_STREAM_PROTECT_ROWS_DEFAULT, 2_000_000)
    assert_equal(AGG_INMEM_MAX_ROWS_DEFAULT, 4_000_000)
    assert_equal(c.fact_stream_protect_threshold(), 2_000_000)
    assert_equal(c.agg_inmem_ceiling_rows(), 4_000_000)
    assert_true(c.semi_pushdown)
    assert_true(c.eager_agg)


def test_agg_inmem_ceiling_positive_value_is_used() raises:
    """A positive ceiling is returned as set. Catches a clamp that ignores the
    field and always answers the default."""
    var c = OptimizerConfig()
    c.agg_inmem_max_rows = 1
    assert_equal(c.agg_inmem_ceiling_rows(), 1)
    c.agg_inmem_max_rows = 123
    assert_equal(c.agg_inmem_ceiling_rows(), 123)


def test_agg_inmem_ceiling_non_positive_falls_back() raises:
    """0 and -1 mean the default. Catches `> 0` weakened to `>= 0` (0 returned
    as the ceiling) and a negative value returned as a ceiling."""
    var c = OptimizerConfig()
    c.agg_inmem_max_rows = 0
    assert_equal(c.agg_inmem_ceiling_rows(), AGG_INMEM_MAX_ROWS_DEFAULT)
    c.agg_inmem_max_rows = -1
    assert_equal(c.agg_inmem_ceiling_rows(), AGG_INMEM_MAX_ROWS_DEFAULT)


def test_fact_stream_threshold_positive_value_is_used() raises:
    """A positive threshold is returned as set. Catches a clamp that ignores
    the field."""
    var c = OptimizerConfig()
    c.fact_stream_protect_rows = 1
    assert_equal(c.fact_stream_protect_threshold(), 1)
    c.fact_stream_protect_rows = 64
    assert_equal(c.fact_stream_protect_threshold(), 64)


def test_fact_stream_threshold_non_positive_falls_back() raises:
    """0 and -1 mean the default. Catches `> 0` weakened to `>= 0` (0 returned
    as the threshold)."""
    var c = OptimizerConfig()
    c.fact_stream_protect_rows = 0
    assert_equal(c.fact_stream_protect_threshold(), FACT_STREAM_PROTECT_ROWS_DEFAULT)
    c.fact_stream_protect_rows = -1
    assert_equal(c.fact_stream_protect_threshold(), FACT_STREAM_PROTECT_ROWS_DEFAULT)


def test_copy_is_independent() raises:
    """The config is a value: a copy changed by one caller does not change the
    original. Catches a reference-semantics regression in the struct."""
    var a = OptimizerConfig()
    var b = a.copy()
    b.disable_scan_dedup = True
    b.agg_inmem_max_rows = 7
    assert_false(a.disable_scan_dedup)
    assert_equal(a.agg_inmem_max_rows, 4_000_000)
    assert_true(b.disable_scan_dedup)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
