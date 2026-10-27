# The value checks on fixed inputs: the order-independent signature, the
# tolerance rules and the row-order check. No engine and no process.
#
# What each test proves:
# - test_the_signature_ignores_row_order: the same rows in two orders compare
#   identical; a changed cell, a missing row and an extra row do not.
# - test_a_float_sum_passes_within_the_relative_tolerance: a difference of
#   5e-10 relative on a 1e9-sized sum passes and 1e-8 relative fails.
# - test_the_absolute_floor_covers_values_near_zero: 0 against 5e-7 passes,
#   0 against 2e-6 fails, and the relative tolerance alone would refuse both.
# - test_integer_sums_are_exact_at_any_size: an integer sum off by one fails
#   and the mode says exact; past 2^53 (sums, sums of squares, and sums that
#   wrap past 2^64) the same rows in another order stay identical while a
#   sum of squares that differs by 2 out of 4e16, or a sum off by one, fails.
# - test_null_nan_kind_and_count_differences_are_divergent: a null where the
#   other side has a value, a NaN count and a column against a text column
#   are divergent.
# - test_integers_against_doubles_compare_as_numbers: [1,2] against [1.0,2.0]
#   is identical in tolerance mode, [1,2] against [1.0,2.5] is not.
# - test_the_tolerance_holds_at_a_large_scale: on a 1e12-sized value, 4e-10
#   relative passes and 2e-9 relative fails.
# - test_a_difference_in_only_the_float_minimum_is_found: two double sets with
#   the same count, sum, sum of squares and maximum and different minimums are
#   divergent.
# - test_equal_infinities_are_close_and_unequal_ones_are_not: the same
#   infinity compares equal, opposite infinities and an infinity against a
#   finite value do not, NaN is close to nothing, and a sum of squares that
#   overflowed on both sides compares equal.
# - test_results_with_no_rows_compare_without_their_columns: no rows against
#   no rows is identical whatever the column counts, no rows against a row is
#   not.
# - test_text_columns_compare_every_cell: the same texts in another order are
#   identical; a changed byte, a longer text and a different smallest text are
#   not, and neither is a change to a middle cell that keeps the total length
#   and both extremes.
# - test_the_order_check_follows_the_keys: ascending, descending, two keys,
#   ties, nulls last and nulls first, text keys, a violation names its row,
#   and a key column out of range raises.
# - test_the_order_check_is_exact_for_large_integers_and_places_nan_last:
#   integers 2^53 and 2^53+1 are in order and out of order as written, and a
#   NaN sorts after every number.
# - test_a_mismatched_row_width_raises: a row with a missing cell is refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    Cell,
    OrderKey,
    ResultSet,
    check_order,
    compare_signatures,
    numbers_close,
    signature_of,
)


def _ints(values: List[Int]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    for v in values:
        var row = List[Cell]()
        row.append(Cell.integer(Int64(v)))
        rs.add_row(row^)
    return rs^


def _floats(values: List[Float64]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    for v in values:
        var row = List[Cell]()
        row.append(Cell.real(v))
        rs.add_row(row^)
    return rs^


def _same(a: ResultSet, b: ResultSet) raises -> Bool:
    return compare_signatures(signature_of(a), signature_of(b)).identical


def test_the_signature_ignores_row_order() raises:
    var a = List[Int]()
    a.append(5)
    a.append(1)
    a.append(9)
    var b = List[Int]()
    b.append(9)
    b.append(5)
    b.append(1)
    assert_true(_same(_ints(a), _ints(b)))
    var changed = List[Int]()
    changed.append(9)
    changed.append(5)
    changed.append(2)
    assert_false(_same(_ints(a), _ints(changed)))
    var fewer = List[Int]()
    fewer.append(9)
    fewer.append(5)
    assert_false(_same(_ints(a), _ints(fewer)))
    var more = List[Int]()
    more.append(9)
    more.append(5)
    more.append(1)
    more.append(0)
    assert_false(_same(_ints(a), _ints(more)))


def test_a_float_sum_passes_within_the_relative_tolerance() raises:
    var base = List[Float64]()
    base.append(1.0e9)
    var near = List[Float64]()
    near.append(1.0e9 * (1.0 + 5.0e-10))
    var far = List[Float64]()
    far.append(1.0e9 * (1.0 + 1.0e-8))
    assert_true(_same(_floats(base), _floats(near)))
    assert_false(_same(_floats(base), _floats(far)))
    assert_true(numbers_close(1.0e9, 1.0e9 * (1.0 + 5.0e-10), 1e-9, 1e-6))
    assert_false(numbers_close(1.0e9, 1.0e9 * (1.0 + 1.0e-8), 1e-9, 1e-6))


def test_the_absolute_floor_covers_values_near_zero() raises:
    var zero = List[Float64]()
    zero.append(0.0)
    var tiny = List[Float64]()
    tiny.append(5.0e-7)
    var small = List[Float64]()
    small.append(2.0e-6)
    assert_true(_same(_floats(zero), _floats(tiny)))
    assert_false(_same(_floats(zero), _floats(small)))
    assert_false(numbers_close(0.0, 5.0e-7, 1e-9, 0.0))


def test_integer_sums_are_exact_at_any_size() raises:
    var a = List[Int]()
    a.append(100)
    a.append(200)
    a.append(300)
    var b = List[Int]()
    b.append(100)
    b.append(200)
    b.append(301)
    var v = compare_signatures(signature_of(_ints(a)), signature_of(_ints(b)))
    assert_false(v.identical)
    var saw_exact_sum = False
    for m in v.modes:
        if m == "column 0.sum=exact":
            saw_exact_sum = True
    assert_true(saw_exact_sum)
    # Squares past 2^53 (values near 1e8 square to about 1e16): two sets with
    # the same count, sum, minimum and maximum and a sum of squares that
    # differs by 2 out of 4e16 are divergent.
    var sq_a = List[Int]()
    sq_a.append(100_000_000)
    sq_a.append(100_000_001)
    sq_a.append(100_000_001)
    sq_a.append(100_000_002)
    var sq_b = List[Int]()
    sq_b.append(100_000_000)
    sq_b.append(100_000_000)
    sq_b.append(100_000_002)
    sq_b.append(100_000_002)
    var sig = signature_of(_ints(sq_a))
    var vq = compare_signatures(sig, signature_of(_ints(sq_b)))
    assert_false(vq.identical)
    assert_equal(len(vq.reasons), 1)
    # the same rows in another order stay identical
    var sq_a_reordered = List[Int]()
    sq_a_reordered.append(100_000_002)
    sq_a_reordered.append(100_000_001)
    sq_a_reordered.append(100_000_000)
    sq_a_reordered.append(100_000_001)
    assert_true(compare_signatures(sig, signature_of(_ints(sq_a_reordered))).identical)
    # four values of 4e15 sum past 2^53; one more in the last place differs
    var big_a = List[Int]()
    var big_b = List[Int]()
    for _ in range(4):
        big_a.append(4_000_000_000_000_000)
        big_b.append(4_000_000_000_000_000)
    big_b[3] = 4_000_000_000_000_001
    assert_false(_same(_ints(big_a), _ints(big_b)))
    # values near 2^62 wrap the 64-bit sums; order still does not matter, and
    # a changed value still shows
    var wrap_a = List[Int]()
    wrap_a.append(4_611_686_018_427_387_904)
    wrap_a.append(4_611_686_018_427_387_903)
    wrap_a.append(-4_611_686_018_427_387_904)
    wrap_a.append(9_223_372_036_854_775_807)
    var wrap_b = List[Int]()
    wrap_b.append(9_223_372_036_854_775_807)
    wrap_b.append(-4_611_686_018_427_387_904)
    wrap_b.append(4_611_686_018_427_387_903)
    wrap_b.append(4_611_686_018_427_387_904)
    assert_true(_same(_ints(wrap_a), _ints(wrap_b)))
    wrap_b[2] = 4_611_686_018_427_387_902
    assert_false(_same(_ints(wrap_a), _ints(wrap_b)))


def test_null_nan_kind_and_count_differences_are_divergent() raises:
    var with_value = ResultSet()
    with_value.names.append(String("v"))
    var r1 = List[Cell]()
    r1.append(Cell.integer(Int64(1)))
    with_value.add_row(r1^)
    var r2 = List[Cell]()
    r2.append(Cell.integer(Int64(2)))
    with_value.add_row(r2^)
    var with_null = ResultSet()
    with_null.names.append(String("v"))
    var n1 = List[Cell]()
    n1.append(Cell.integer(Int64(1)))
    with_null.add_row(n1^)
    var n2 = List[Cell]()
    n2.append(Cell.null())
    with_null.add_row(n2^)
    assert_false(_same(with_value, with_null))

    var nan_a = List[Float64]()
    nan_a.append(1.0)
    nan_a.append(2.0)
    var plain = _floats(nan_a)
    var nan_rs = ResultSet()
    nan_rs.names.append(String("v"))
    var f1 = List[Cell]()
    f1.append(Cell.real(1.0))
    nan_rs.add_row(f1^)
    var f2 = List[Cell]()
    var big = Float64.MAX * 2.0
    f2.append(Cell.real(big - big))
    nan_rs.add_row(f2^)
    assert_false(_same(plain, nan_rs))

    var ints = List[Int]()
    ints.append(1)
    ints.append(2)

    var text = ResultSet()
    text.names.append(String("v"))
    var t1 = List[Cell]()
    t1.append(Cell.text(String("1")))
    text.add_row(t1^)
    var t2 = List[Cell]()
    t2.append(Cell.text(String("2")))
    text.add_row(t2^)
    assert_false(_same(_ints(ints), text))


def test_integers_against_doubles_compare_as_numbers() raises:
    var ints = List[Int]()
    ints.append(1)
    ints.append(2)
    var same = List[Float64]()
    same.append(1.0)
    same.append(2.0)
    var other = List[Float64]()
    other.append(1.0)
    other.append(2.5)
    var v = compare_signatures(signature_of(_ints(ints)), signature_of(_floats(same)))
    assert_true(v.identical)
    var saw_tolerance = False
    for m in v.modes:
        if m == "column 0.sum=tolerance":
            saw_tolerance = True
    assert_true(saw_tolerance)
    assert_true(compare_signatures(signature_of(_floats(same)), signature_of(_ints(ints))).identical)
    assert_false(_same(_ints(ints), _floats(other)))


def test_the_tolerance_holds_at_a_large_scale() raises:
    var base = List[Float64]()
    base.append(1.0e12)
    var near = List[Float64]()
    near.append(1.0e12 * (1.0 + 4.0e-10))
    var far = List[Float64]()
    far.append(1.0e12 * (1.0 + 2.0e-9))
    assert_true(_same(_floats(base), _floats(near)))
    assert_false(_same(_floats(base), _floats(far)))
    assert_false(numbers_close(1.0e12, 1.0e12 + 2000.0, 1e-9, 1e-6))
    assert_true(numbers_close(1.0e12, 1.0e12 + 500.0, 1e-9, 1e-6))


def test_a_difference_in_only_the_float_minimum_is_found() raises:
    # {0.5, 2.5, 3, 5} and {1, 1.5, 3.5, 5}: sum 11 and sum of squares 40.5
    # on both sides, maximum 5, minimum 0.5 against 1.
    var a = List[Float64]()
    a.append(0.5)
    a.append(2.5)
    a.append(3.0)
    a.append(5.0)
    var b = List[Float64]()
    b.append(1.0)
    b.append(1.5)
    b.append(3.5)
    b.append(5.0)
    var v = compare_signatures(signature_of(_floats(a)), signature_of(_floats(b)))
    assert_false(v.identical)
    assert_equal(len(v.reasons), 1)
    assert_true(v.reasons[0].find(String("minimum")) >= 0)


def test_equal_infinities_are_close_and_unequal_ones_are_not() raises:
    var inf = Float64.MAX * 2.0
    var nan = inf - inf
    assert_true(numbers_close(inf, inf, 1e-9, 1e-6))
    assert_true(numbers_close(-inf, -inf, 1e-9, 1e-6))
    assert_false(numbers_close(inf, -inf, 1e-9, 1e-6))
    assert_false(numbers_close(inf, 1.0e300, 1e-9, 1e-6))
    assert_false(numbers_close(nan, nan, 1e-9, 1e-6))
    # 1e200 squared overflows to infinity on both sides
    var a = List[Float64]()
    a.append(1.0e200)
    var b = List[Float64]()
    b.append(1.0e200)
    assert_true(_same(_floats(a), _floats(b)))
    var c = List[Float64]()
    c.append(inf)
    assert_true(_same(_floats(c), _floats(c)))
    var d = List[Float64]()
    d.append(-inf)
    assert_false(_same(_floats(c), _floats(d)))


def test_results_with_no_rows_compare_without_their_columns() raises:
    var empty_named = ResultSet()
    empty_named.names.append(String("a"))
    empty_named.names.append(String("b"))
    var empty_bare = ResultSet()
    assert_true(_same(empty_named, empty_bare))
    assert_true(_same(empty_bare, empty_bare))
    var one = List[Int]()
    one.append(1)
    assert_false(_same(empty_bare, _ints(one)))


def _texts(values: List[String]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("t"))
    for v in values:
        var row = List[Cell]()
        row.append(Cell.text(v))
        rs.add_row(row^)
    return rs^


def test_text_columns_compare_every_cell() raises:
    var a = List[String]()
    a.append(String("pear"))
    a.append(String("apple"))
    a.append(String("fig"))
    var b = List[String]()
    b.append(String("fig"))
    b.append(String("pear"))
    b.append(String("apple"))
    assert_true(_same(_texts(a), _texts(b)))
    var changed = List[String]()
    changed.append(String("fig"))
    changed.append(String("pear"))
    changed.append(String("applf"))
    assert_false(_same(_texts(a), _texts(changed)))
    var longer = List[String]()
    longer.append(String("fig"))
    longer.append(String("pear"))
    longer.append(String("apples"))
    assert_false(_same(_texts(a), _texts(longer)))
    var other_min = List[String]()
    other_min.append(String("fig"))
    other_min.append(String("pear"))
    other_min.append(String("bpple"))
    assert_false(_same(_texts(a), _texts(other_min)))
    # a middle cell changes and the total length, smallest and largest do not
    var x = List[String]()
    x.append(String("aa"))
    x.append(String("bc"))
    x.append(String("zz"))
    var y = List[String]()
    y.append(String("aa"))
    y.append(String("bd"))
    y.append(String("zz"))
    var vx = compare_signatures(signature_of(_texts(x)), signature_of(_texts(y)))
    assert_false(vx.identical)
    assert_equal(len(vx.reasons), 1)


def _two_columns(rows: List[Tuple[Int, Int]]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("a"))
    rs.names.append(String("b"))
    for r in rows:
        var row = List[Cell]()
        row.append(Cell.integer(Int64(r[0])))
        row.append(Cell.integer(Int64(r[1])))
        rs.add_row(row^)
    return rs^


def test_the_order_check_follows_the_keys() raises:
    var rows = List[Tuple[Int, Int]]()
    rows.append((1, 9))
    rows.append((1, 5))
    rows.append((2, 7))
    rows.append((2, 7))
    var asc_a = List[OrderKey]()
    asc_a.append(OrderKey(0))
    assert_true(check_order(_two_columns(rows), asc_a).ok)
    var asc_ab = List[OrderKey]()
    asc_ab.append(OrderKey(0))
    asc_ab.append(OrderKey(1))
    var v = check_order(_two_columns(rows), asc_ab)
    assert_false(v.ok)
    assert_equal(v.row, 1)
    var a_asc_b_desc = List[OrderKey]()
    a_asc_b_desc.append(OrderKey(0))
    a_asc_b_desc.append(OrderKey(1, True))
    assert_true(check_order(_two_columns(rows), a_asc_b_desc).ok)
    var desc_a = List[OrderKey]()
    desc_a.append(OrderKey(0, True))
    assert_false(check_order(_two_columns(rows), desc_a).ok)

    var with_null = ResultSet()
    with_null.names.append(String("a"))
    var c1 = List[Cell]()
    c1.append(Cell.integer(Int64(3)))
    with_null.add_row(c1^)
    var c2 = List[Cell]()
    c2.append(Cell.null())
    with_null.add_row(c2^)
    assert_true(check_order(with_null, asc_a).ok)
    var nulls_first = List[OrderKey]()
    nulls_first.append(OrderKey(0, False, True))
    assert_false(check_order(with_null, nulls_first).ok)
    var desc_nulls_last = List[OrderKey]()
    desc_nulls_last.append(OrderKey(0, True))
    assert_true(check_order(with_null, desc_nulls_last).ok)

    var words = List[String]()
    words.append(String("apple"))
    words.append(String("apples"))
    words.append(String("b"))
    assert_true(check_order(_texts(words), asc_a).ok)
    var backwards = List[String]()
    backwards.append(String("b"))
    backwards.append(String("apple"))
    assert_false(check_order(_texts(backwards), asc_a).ok)

    var out_of_range = List[OrderKey]()
    out_of_range.append(OrderKey(2))
    var raised = False
    try:
        _ = check_order(_two_columns(rows), out_of_range)
    except:
        raised = True
    assert_true(raised)


def test_the_order_check_is_exact_for_large_integers_and_places_nan_last() raises:
    var keys = List[OrderKey]()
    keys.append(OrderKey(0))
    var in_order = ResultSet()
    in_order.names.append(String("a"))
    var r1 = List[Cell]()
    r1.append(Cell.integer(Int64(9_007_199_254_740_992)))
    in_order.add_row(r1^)
    var r2 = List[Cell]()
    r2.append(Cell.integer(Int64(9_007_199_254_740_993)))
    in_order.add_row(r2^)
    assert_true(check_order(in_order, keys).ok)
    var reversed = ResultSet()
    reversed.names.append(String("a"))
    var q1 = List[Cell]()
    q1.append(Cell.integer(Int64(9_007_199_254_740_993)))
    reversed.add_row(q1^)
    var q2 = List[Cell]()
    q2.append(Cell.integer(Int64(9_007_199_254_740_992)))
    reversed.add_row(q2^)
    assert_false(check_order(reversed, keys).ok)

    var big = Float64.MAX * 2.0
    var nan = big - big
    var nan_last = ResultSet()
    nan_last.names.append(String("a"))
    var n1 = List[Cell]()
    n1.append(Cell.real(1.0e300))
    nan_last.add_row(n1^)
    var n2 = List[Cell]()
    n2.append(Cell.real(nan))
    nan_last.add_row(n2^)
    var n3 = List[Cell]()
    n3.append(Cell.real(nan))
    nan_last.add_row(n3^)
    assert_true(check_order(nan_last, keys).ok)
    var nan_first = ResultSet()
    nan_first.names.append(String("a"))
    var m1 = List[Cell]()
    m1.append(Cell.real(nan))
    nan_first.add_row(m1^)
    var m2 = List[Cell]()
    m2.append(Cell.real(1.0))
    nan_first.add_row(m2^)
    assert_false(check_order(nan_first, keys).ok)


def test_a_mismatched_row_width_raises() raises:
    var rs = ResultSet()
    rs.names.append(String("a"))
    rs.names.append(String("b"))
    var row = List[Cell]()
    row.append(Cell.integer(Int64(1)))
    rs.add_row(row^)
    var raised = False
    try:
        _ = signature_of(rs)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
