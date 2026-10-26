# =============================================================================
# ConstantFilter: one build-side key, one equality compare per probe row
# =============================================================================
#
# matches_int64 is True exactly for the key, never for a neighbour, across
# zero, negative keys and both Int64 ends; a filter built with has_null
# rejects every probe, its own key included; the accessors report what
# was built, and a copy keeps both fields.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dynamic_filter.constant_filter import ConstantFilter


def _keys() -> List[Int64]:
    return [0, 1, -1, 42, -42, 0x0123456789ABCDEF, Int64.MIN, Int64.MAX]


def test_matches_only_the_key() raises:
    var keys = _keys()
    for i in range(len(keys)):
        var k = keys[i]
        var f = ConstantFilter(k)
        assert_false(f.has_null(), "single-value constructor has no null")
        assert_equal(f.value_int64(), k)
        assert_true(f.matches_int64(k), "key " + String(k))
        if k != Int64.MAX:
            assert_false(f.matches_int64(k + 1), "key + 1 of " + String(k))
        if k != Int64.MIN:
            assert_false(f.matches_int64(k - 1), "key - 1 of " + String(k))
        for j in range(len(keys)):
            assert_equal(f.matches_int64(keys[j]), keys[j] == k, "probe " + String(keys[j]) + " of " + String(k))


def test_explicit_has_null_false_matches_like_single_value() raises:
    var keys = _keys()
    for i in range(len(keys)):
        var f = ConstantFilter(keys[i], has_null=False)
        assert_false(f.has_null())
        assert_equal(f.value_int64(), keys[i])
        for j in range(len(keys)):
            assert_equal(f.matches_int64(keys[j]), i == j, "probe " + String(keys[j]))


def test_has_null_rejects_every_probe() raises:
    var keys = _keys()
    for i in range(len(keys)):
        var f = ConstantFilter(keys[i], has_null=True)
        assert_true(f.has_null())
        assert_equal(f.value_int64(), keys[i], "value is kept")
        for j in range(len(keys)):
            assert_false(f.matches_int64(keys[j]), "NULL build side joins nothing: " + String(keys[j]))


def test_copy_keeps_value_and_null() raises:
    var a = ConstantFilter(Int64(-7), has_null=True)
    var b = a.copy()
    assert_equal(b.value_int64(), Int64(-7))
    assert_true(b.has_null())
    var c = ConstantFilter(Int64(9)).copy()
    assert_true(c.matches_int64(9))
    assert_false(c.has_null())
    var d = ConstantFilter(Int64(9), has_null=True).copy()
    assert_false(d.matches_int64(9), "a copy keeps the null sentinel")
    assert_true(d.has_null())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
