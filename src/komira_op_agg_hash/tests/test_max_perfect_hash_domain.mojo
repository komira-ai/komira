# =============================================================================
# _MAX_PERFECT_HASH_DOMAIN -- the perfect-hash domain cap
# =============================================================================
#
# The PerfectHashAggregator domain cap is 65,536 keys. A wider cap needs
# bench evidence (see flat_hash_agg_perfect.mojo), so a change here must be
# deliberate: test 1 fails when the constant drifts.
#
# Test 2 checks the cap against its consumer: the type-only strategy
# selector of komira_agg_api picks PerfectHash for 16-bit keys with a
# 65,536-key domain, which the aggregator must accept. It fails if the
# cap is lowered below what the selector hands out.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_agg_api.agg_strategy import (
    AGG_STRATEGY_PERFECT_HASH,
    select_optimal_strategy_type_only,
)
from komira_op_agg_hash.flat_hash_agg_perfect import _MAX_PERFECT_HASH_DOMAIN


def test_max_perfect_hash_domain_value() raises:
    """`_MAX_PERFECT_HASH_DOMAIN` is 65,536."""
    assert_equal(_MAX_PERFECT_HASH_DOMAIN, 65_536)


def test_type_only_selection_fits_the_cap() raises:
    """Every perfect-hash domain the type-only selector picks for a single
    key fits under the aggregator's cap."""
    var types = List[ArrowType]()
    types.append(ArrowType.BOOL)
    types.append(ArrowType.INT8)
    types.append(ArrowType.UINT8)
    types.append(ArrowType.INT16)
    types.append(ArrowType.UINT16)
    var widest = 0
    for i in range(len(types)):
        var keys = List[ArrowType]()
        keys.append(types[i])
        var strategy = select_optimal_strategy_type_only(keys)
        assert_equal(strategy.tag, AGG_STRATEGY_PERFECT_HASH)
        assert_true(strategy.domain_size <= _MAX_PERFECT_HASH_DOMAIN)
        if strategy.domain_size > widest:
            widest = strategy.domain_size
    # The 16-bit types reach the cap exactly.
    assert_equal(widest, _MAX_PERFECT_HASH_DOMAIN)


def main() raises:
    test_max_perfect_hash_domain_value()
    test_type_only_selection_fits_the_cap()
    print("PASS: test_max_perfect_hash_domain")
