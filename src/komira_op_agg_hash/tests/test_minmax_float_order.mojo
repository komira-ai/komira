# =============================================================================
# Tests -- MIN/MAX of the hash tables under the NaN-greatest float order
# =============================================================================
#
# MIN and MAX order NaN above +inf (komira_udf.float_quotient_order, the
# order komira_op_agg_state's MinF64/MaxF64 use and DuckDB answers with).
# The quartet slot is therefore seeded with each fold's identity: MIN with
# the canonical NaN, MAX with -inf. Every case below is one group:
#
#   values                  MIN    MAX
#   {+inf}                  +inf   +inf
#   {-inf}                  -inf   -inf
#   {NaN}                   NaN    NaN
#   {NaN, 1.0}              1.0    NaN
#   {1.0, NaN, -inf, +inf}  -inf   NaN
#
# Each case runs through the flat table (update, then merge into an empty
# table and into a table holding half of the values) and through the
# perfect-hash table (update, then merge the same way).
#
# What fails without the seeds: seeding MIN with Float64.MAX makes MIN of
# {+inf} and of {NaN} answer 1.797e308; seeding MAX with the lowest finite
# Float64 makes MAX of {-inf} answer -1.797e308. Both seeds were planted
# back (flat table and perfect-hash table separately) and these tests went
# red; a fold that orders NaN least instead of greatest fails the
# {NaN, 1.0} and mixed rows.
# =============================================================================

from std.math import inf, isnan
from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator
from komira_op_agg_hash.flat_hash_agg_perfect import PerfectHashAggregator


comptime _NUM_CASES: Int = 5


def _nan() -> Float64:
    var zero = Float64(0.0)
    return zero / zero


def _case_values(c: Int) -> List[Float64]:
    var v = List[Float64]()
    if c == 0:
        v.append(inf[DType.float64]())
    elif c == 1:
        v.append(-inf[DType.float64]())
    elif c == 2:
        v.append(_nan())
    elif c == 3:
        v.append(_nan())
        v.append(1.0)
    else:
        v.append(1.0)
        v.append(_nan())
        v.append(-inf[DType.float64]())
        v.append(inf[DType.float64]())
    return v^


def _assert_f64(got: Float64, want: Float64, what: String) raises:
    """Bit-faithful compare that treats NaN as equal to NaN."""
    if isnan(want):
        assert_true(isnan(got), what + ": want NaN, got " + String(got))
    else:
        assert_equal(got, want, what)


def _check(c: Int, got_min: Float64, got_max: Float64, where: String) raises:
    var want_min: Float64
    var want_max: Float64
    if c == 0:
        want_min = inf[DType.float64]()
        want_max = inf[DType.float64]()
    elif c == 1:
        want_min = -inf[DType.float64]()
        want_max = -inf[DType.float64]()
    elif c == 2:
        want_min = _nan()
        want_max = _nan()
    elif c == 3:
        want_min = 1.0
        want_max = _nan()
    else:
        want_min = -inf[DType.float64]()
        want_max = _nan()
    _assert_f64(got_min, want_min, where + " MIN case " + String(c))
    _assert_f64(got_max, want_max, where + " MAX case " + String(c))


def test_flat_table_min_max_float_order() raises:
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)
    for c in range(_NUM_CASES):
        var vals = _case_values(c)
        for i in range(len(vals)):
            var h = agg.find_or_create_1(Int64(c))
            agg._update_agg(h, 0, vals[i])
    for c in range(_NUM_CASES):
        var h = agg.find_or_create_1(Int64(c))
        _check(c, agg.get_min(h, 0), agg.get_max(h, 0), "flat")


def test_flat_table_merge_min_max_float_order() raises:
    # `a` gets the even-indexed values of each case, `b` the odd ones, so
    # single-value cases leave `a` with no entry for that key: the merge
    # creates it from the seed. `empty` receives everything by merge only.
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    var b = FlatHashAggregator(num_keys=1, num_aggs=1)
    var empty = FlatHashAggregator(num_keys=1, num_aggs=1)
    for c in range(_NUM_CASES):
        var vals = _case_values(c)
        for i in range(len(vals)):
            # Single values go to `b`, so `a` has no group for them.
            if len(vals) > 1 and i % 2 == 0:
                var h = a.find_or_create_1(Int64(c))
                a._update_agg(h, 0, vals[i])
            else:
                var h = b.find_or_create_1(Int64(c))
                b._update_agg(h, 0, vals[i])
    a.merge(b)
    empty.merge(a)
    assert_equal(a.num_groups(), _NUM_CASES)
    assert_equal(empty.num_groups(), _NUM_CASES)
    for c in range(_NUM_CASES):
        var ha = a.find_or_create_1(Int64(c))
        _check(c, a.get_min(ha, 0), a.get_max(ha, 0), "flat merge")
        var he = empty.find_or_create_1(Int64(c))
        _check(c, empty.get_min(he, 0), empty.get_max(he, 0), "flat merge into empty")


def test_perfect_table_min_max_float_order() raises:
    var agg = PerfectHashAggregator(domain_size=8, key_offset=0, num_aggs=1)
    for c in range(_NUM_CASES):
        var vals = _case_values(c)
        for i in range(len(vals)):
            agg.update(Int64(c), 0, vals[i])
    for c in range(_NUM_CASES):
        _check(c, agg.get_min(c, 0), agg.get_max(c, 0), "perfect")


def test_perfect_table_merge_min_max_float_order() raises:
    var a = PerfectHashAggregator(domain_size=8, key_offset=0, num_aggs=1)
    var b = PerfectHashAggregator(domain_size=8, key_offset=0, num_aggs=1)
    var empty = PerfectHashAggregator(domain_size=8, key_offset=0, num_aggs=1)
    for c in range(_NUM_CASES):
        var vals = _case_values(c)
        for i in range(len(vals)):
            if len(vals) > 1 and i % 2 == 0:
                a.update(Int64(c), 0, vals[i])
            else:
                b.update(Int64(c), 0, vals[i])
    a.merge(b)
    empty.merge(a)
    for c in range(_NUM_CASES):
        _check(c, a.get_min(c, 0), a.get_max(c, 0), "perfect merge")
        _check(c, empty.get_min(c, 0), empty.get_max(c, 0), "perfect merge into empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
