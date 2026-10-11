# =============================================================================
# Unit tests for expr_sortable_key.mojo: SortKeyComponent, the 3-valued
# component comparator and the per-arity lexicographic comparators
# =============================================================================
#
# What the tests hold the code to (its docstrings):
#   - a component compares -1 / 0 / +1 by value within its kind;
#   - NULLS LAST under ascending: a null is greater than any non-null, two
#     nulls are equal;
#   - SORT_DIR_DESC negates a component's result (null placement included,
#     since the negation is applied after the null rule); any other dir
#     value passes the result through;
#   - earlier components decide; a later one is read only on a tie.
#
# NaN is left out on purpose: `_cmp_float64` documents that NaN is not
# ordered by it, so no NaN answer is a contract to pin. Mixed-kind
# comparisons are documented as undefined and are not pinned either.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_expr.expr_sortable_key import (
    SORT_DIR_ASC,
    SORT_DIR_DESC,
    SORT_ALGO_MERGE,
    SORT_ALGO_RADIX,
    SORT_ALGO_QUICK,
    SKC_INT64,
    SKC_FLOAT64,
    SKC_STRING,
    SortKeyComponent,
    SortKeyValue1,
    SortKeyValue2,
    SortKeyValue3,
    cmp_sort_key_component,
    cmp_sort_key_value1,
    cmp_sort_key_value2,
    cmp_sort_key_value3,
)


def _i(v: Int, null: Bool = False) -> SortKeyComponent:
    return SortKeyComponent(Int64(v), null)


def _f(v: Float64, null: Bool = False) -> SortKeyComponent:
    return SortKeyComponent(v, null)


def _s(v: String, null: Bool = False) -> SortKeyComponent:
    return SortKeyComponent(v, null)


def _cmp(a: SortKeyComponent, b: SortKeyComponent) -> Int:
    return Int(cmp_sort_key_component(a, b))


def test_constants() raises:
    assert_equal(SORT_DIR_ASC, UInt8(0))
    assert_equal(SORT_DIR_DESC, UInt8(1))
    assert_equal(SORT_ALGO_MERGE, UInt8(0))
    assert_equal(SORT_ALGO_RADIX, UInt8(1))
    assert_equal(SORT_ALGO_QUICK, UInt8(2))
    assert_equal(SKC_INT64, UInt8(1))
    assert_equal(SKC_FLOAT64, UInt8(2))
    assert_equal(SKC_STRING, UInt8(3))


def test_component_kind_and_null_flag() raises:
    """Each ctor sets its kind; is_null reads the active arm's flag."""
    assert_equal(_i(1).kind, SKC_INT64)
    assert_equal(_f(1.0).kind, SKC_FLOAT64)
    assert_equal(_s("x").kind, SKC_STRING)
    assert_false(_i(1).is_null())
    assert_true(_i(1, True).is_null())
    assert_false(_f(1.0).is_null())
    assert_true(_f(1.0, True).is_null())
    assert_false(_s("x").is_null())
    assert_true(_s("x", True).is_null())


def test_component_unknown_kind_is_not_null() raises:
    """A kind outside the three arms reports not-null."""
    var c = _i(1, True)
    c.kind = UInt8(77)
    assert_false(c.is_null())


def test_cmp_int64() raises:
    assert_equal(_cmp(_i(-5), _i(3)), -1)
    assert_equal(_cmp(_i(3), _i(-5)), 1)
    assert_equal(_cmp(_i(3), _i(3)), 0)
    # Extremes: no subtraction overflow in the comparator.
    assert_equal(_cmp(_i(Int(Int64.MIN)), _i(Int(Int64.MAX))), -1)
    assert_equal(_cmp(_i(Int(Int64.MAX)), _i(Int(Int64.MIN))), 1)


def test_cmp_float64() raises:
    assert_equal(_cmp(_f(1.5), _f(2.5)), -1)
    assert_equal(_cmp(_f(2.5), _f(1.5)), 1)
    assert_equal(_cmp(_f(2.5), _f(2.5)), 0)
    # IEEE: -0.0 == +0.0.
    assert_equal(_cmp(_f(-0.0), _f(0.0)), 0)
    assert_equal(_cmp(_f(-1.0e300), _f(1.0e300)), -1)


def test_cmp_string_bytewise() raises:
    assert_equal(_cmp(_s("apple"), _s("banana")), -1)
    assert_equal(_cmp(_s("banana"), _s("apple")), 1)
    assert_equal(_cmp(_s("same"), _s("same")), 0)
    # A proper prefix sorts first; "Z" (0x5A) sorts before "a" (0x61).
    assert_equal(_cmp(_s("ab"), _s("abc")), -1)
    assert_equal(_cmp(_s(""), _s("a")), -1)
    assert_equal(_cmp(_s("Z"), _s("a")), -1)


def test_cmp_nulls_last() raises:
    """Null vs null 0; null vs value +1; value vs null -1, for every kind.
    The null's payload is never read (a null 0 still sorts after 100)."""
    assert_equal(_cmp(_i(0, True), _i(9, True)), 0)
    assert_equal(_cmp(_i(0, True), _i(100)), 1)
    assert_equal(_cmp(_i(100), _i(0, True)), -1)
    assert_equal(_cmp(_f(0.0, True), _f(-5.0)), 1)
    assert_equal(_cmp(_f(-5.0), _f(0.0, True)), -1)
    assert_equal(_cmp(_s("", True), _s("zzz")), 1)
    assert_equal(_cmp(_s("zzz"), _s("", True)), -1)


def test_cmp_unknown_kind_is_equal() raises:
    """Two non-null cells of a kind outside the three arms compare 0."""
    var a = _i(1)
    var b = _i(2)
    a.kind = UInt8(77)
    b.kind = UInt8(77)
    assert_equal(_cmp(a, b), 0)


def test_value1_direction() raises:
    var lo = SortKeyValue1(_i(1))
    var hi = SortKeyValue1(_i(2))
    assert_equal(Int(cmp_sort_key_value1(lo, hi, SORT_DIR_ASC)), -1)
    assert_equal(Int(cmp_sort_key_value1(lo, hi, SORT_DIR_DESC)), 1)
    assert_equal(Int(cmp_sort_key_value1(hi, lo, SORT_DIR_DESC)), -1)
    assert_equal(Int(cmp_sort_key_value1(lo, lo, SORT_DIR_DESC)), 0)
    # Any dir other than DESC passes the comparison through.
    assert_equal(Int(cmp_sort_key_value1(lo, hi, UInt8(7))), -1)
    # DESC negates the null rule too: the null sorts first.
    var n = SortKeyValue1(_i(0, True))
    assert_equal(Int(cmp_sort_key_value1(n, lo, SORT_DIR_ASC)), 1)
    assert_equal(Int(cmp_sort_key_value1(n, lo, SORT_DIR_DESC)), -1)


def test_value2_first_component_decides() raises:
    """(1, "z") < (2, "a") ascending: component 0 decides, component 1 is
    not consulted; under DESC on component 0 the order flips."""
    var a = SortKeyValue2(_i(1), _s("z"))
    var b = SortKeyValue2(_i(2), _s("a"))
    assert_equal(Int(cmp_sort_key_value2(a, b, SORT_DIR_ASC, SORT_DIR_ASC)), -1)
    assert_equal(Int(cmp_sort_key_value2(a, b, SORT_DIR_DESC, SORT_DIR_ASC)), 1)


def test_value2_tie_breaks_on_second() raises:
    var a = SortKeyValue2(_i(1), _s("a"))
    var b = SortKeyValue2(_i(1), _s("b"))
    assert_equal(Int(cmp_sort_key_value2(a, b, SORT_DIR_ASC, SORT_DIR_ASC)), -1)
    assert_equal(Int(cmp_sort_key_value2(a, b, SORT_DIR_ASC, SORT_DIR_DESC)), 1)
    # dir0 does not touch a tie on component 0.
    assert_equal(Int(cmp_sort_key_value2(a, b, SORT_DIR_DESC, SORT_DIR_ASC)), -1)
    assert_equal(Int(cmp_sort_key_value2(a, a, SORT_DIR_DESC, SORT_DIR_DESC)), 0)


def test_value3_each_level() raises:
    var base = SortKeyValue3(_i(1), _f(1.0), _s("m"))
    # Component 0 decides.
    var c0 = SortKeyValue3(_i(0), _f(9.0), _s("z"))
    assert_equal(
        Int(cmp_sort_key_value3(c0, base, SORT_DIR_ASC, SORT_DIR_ASC, SORT_DIR_ASC)),
        -1,
    )
    assert_equal(
        Int(cmp_sort_key_value3(c0, base, SORT_DIR_DESC, SORT_DIR_ASC, SORT_DIR_ASC)),
        1,
    )
    # Tie on 0, component 1 decides.
    var c1 = SortKeyValue3(_i(1), _f(2.0), _s("a"))
    assert_equal(
        Int(cmp_sort_key_value3(c1, base, SORT_DIR_ASC, SORT_DIR_ASC, SORT_DIR_ASC)),
        1,
    )
    assert_equal(
        Int(cmp_sort_key_value3(c1, base, SORT_DIR_ASC, SORT_DIR_DESC, SORT_DIR_ASC)),
        -1,
    )
    # Tie on 0 and 1, component 2 decides.
    var c2 = SortKeyValue3(_i(1), _f(1.0), _s("a"))
    assert_equal(
        Int(cmp_sort_key_value3(c2, base, SORT_DIR_ASC, SORT_DIR_ASC, SORT_DIR_ASC)),
        -1,
    )
    assert_equal(
        Int(cmp_sort_key_value3(c2, base, SORT_DIR_ASC, SORT_DIR_ASC, SORT_DIR_DESC)),
        1,
    )
    assert_equal(
        Int(
            cmp_sort_key_value3(base, base, SORT_DIR_DESC, SORT_DIR_DESC, SORT_DIR_DESC)
        ),
        0,
    )


def test_kind_without_payload_falls_back() raises:
    """`kind` is a public field: rewritten to an arm whose payload is
    absent, the component reads not-null and compares by that arm's zero
    value (0, 0.0, "") instead of faulting on an empty Optional."""
    var f_as_i = _f(2.5, True)
    f_as_i.kind = SKC_INT64
    assert_false(f_as_i.is_null())
    var i_as_f = _i(4, True)
    i_as_f.kind = SKC_FLOAT64
    assert_false(i_as_f.is_null())
    var i_as_s = _i(4, True)
    i_as_s.kind = SKC_STRING
    assert_false(i_as_s.is_null())

    # Int64 arm: the payload-less side reads 0.
    var z = _f(9.0)
    z.kind = SKC_INT64
    assert_equal(_cmp(z, _i(5)), -1)
    assert_equal(_cmp(_i(-5), z), -1)
    # Float64 arm.
    var zf = _i(9)
    zf.kind = SKC_FLOAT64
    assert_equal(_cmp(zf, _f(0.5)), -1)
    assert_equal(_cmp(_f(-0.5), zf), -1)
    # String arm: the empty string sorts first.
    var zs = _i(9)
    zs.kind = SKC_STRING
    assert_equal(_cmp(zs, _s("a")), -1)
    assert_equal(_cmp(_s("a"), zs), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
