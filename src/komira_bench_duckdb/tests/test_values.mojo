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
# - test_integer_fields_are_exact_below_two_to_the_53: an integer sum off by
#   one fails and the mode says exact; once the sum of squares passes 2^53 the
#   same off-by-a-relative-1e-12 passes in tolerance mode while the minimum
#   and maximum stay exact.
# - test_an_integer_sum_past_two_to_the_53_is_reported_in_tolerance_mode: the
#   mode list names `tolerance` for the sum.
# - test_null_nan_kind_and_count_differences_are_divergent: a null where the
#   other side has a value, a NaN count, an integer column against a double
#   column and a column against a text column are all divergent.
# - test_text_columns_compare_length_smallest_and_largest: the same texts in
#   another order are identical; a changed byte, a longer text and a different
#   smallest text are not.
# - test_the_order_check_follows_the_keys: ascending, descending, two keys,
#   ties, nulls last and nulls first, text keys, a violation names its row,
#   and a key column out of range raises.
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


def test_integer_fields_are_exact_below_two_to_the_53() raises:
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
    # Squares past 2^53 (values near 1e8 square to about 1e16) leave the sum
    # exact and the sum of squares in tolerance mode: two sets with the same
    # count, sum, minimum and maximum and a sum of squares that differs by 2
    # out of 4e16 are identical, and the mode list says so.
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
    assert_true(sig.columns[0].sum_exact)
    assert_false(sig.columns[0].sumsq_exact)
    var vq = compare_signatures(sig, signature_of(_ints(sq_b)))
    assert_true(vq.identical)
    var saw_tolerance_sumsq = False
    var saw_exact_sum_big = False
    for m in vq.modes:
        if m == "column 0.sumsq=tolerance":
            saw_tolerance_sumsq = True
        if m == "column 0.sum=exact":
            saw_exact_sum_big = True
    assert_true(saw_tolerance_sumsq)
    assert_true(saw_exact_sum_big)
    # an exact field still catches an off-by-one sum
    var sq_c = List[Int]()
    sq_c.append(100_000_000)
    sq_c.append(100_000_001)
    sq_c.append(100_000_001)
    sq_c.append(100_000_003)
    assert_false(compare_signatures(sig, signature_of(_ints(sq_c))).identical)


def test_an_integer_sum_past_two_to_the_53_is_reported_in_tolerance_mode() raises:
    var a = List[Int]()
    var b = List[Int]()
    for i in range(4):
        a.append(4_000_000_000_000_000)
        b.append(4_000_000_000_000_000)
    b[3] = 4_000_000_000_000_001
    var sa = signature_of(_ints(a))
    assert_false(sa.columns[0].sum_exact)
    var v = compare_signatures(sa, signature_of(_ints(b)))
    var saw_tolerance_sum = False
    var saw_exact_max = False
    for m in v.modes:
        if m == "column 0.sum=tolerance":
            saw_tolerance_sum = True
        if m == "column 0.max=exact":
            saw_exact_max = True
    assert_true(saw_tolerance_sum)
    assert_true(saw_exact_max)
    # the exact maximum still sees the difference
    assert_false(v.identical)


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
    assert_false(_same(_ints(ints), _floats(nan_a)))

    var text = ResultSet()
    text.names.append(String("v"))
    var t1 = List[Cell]()
    t1.append(Cell.text(String("1")))
    text.add_row(t1^)
    var t2 = List[Cell]()
    t2.append(Cell.text(String("2")))
    text.add_row(t2^)
    assert_false(_same(_ints(ints), text))


def _texts(values: List[String]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("t"))
    for v in values:
        var row = List[Cell]()
        row.append(Cell.text(v))
        rs.add_row(row^)
    return rs^


def test_text_columns_compare_length_smallest_and_largest() raises:
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
