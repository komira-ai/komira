# Exact decimals: their text, their sums, their place in the value signature,
# the comparison, the row-order check and the recorded form. Pure: no process,
# no clock.
#
# What each test proves:
# - test_decimal_text_has_one_canonical_form: 123.40, 123.4, 0123.4 and
#   123.400 are one value and one text; -0.0 is 0; a missing digit, an
#   exponent, a plus sign and more than 38 fractional digits are refused.
# - test_decimals_are_ordered_by_value: negatives, fractions and different
#   lengths order by value (10 after 9.5, -10 before -9.5), not by text.
# - test_exact_sums_do_not_round_and_do_not_overflow: carries across the limbs,
#   a sum past 128 bits, cancellation to 0, a sign change, the 38th fractional
#   digit, and the same text in any order of terms.
# - test_a_decimal_cell_is_canonical_and_refuses_bad_text: Cell.decimal.
# - test_a_decimal_column_signature_is_exact_and_order_independent: count, sum,
#   minimum and maximum of decimals; rows in another order are identical; a
#   change of the last digit of one cell, or of a scale only, is seen or not
#   seen as it should be.
# - test_integers_among_decimals_are_compared_as_integers: a column of wide
#   integers and small ones compares both parts and finds a change in either.
# - test_a_decimal_column_does_not_compare_with_other_kinds: against integers,
#   texts and doubles it is a difference of kinds that names both; a column of
#   decimals and doubles in one result has no signature to compare.
# - test_the_row_order_check_orders_decimals_by_value: 9.5 then 10.25 is
#   ascending, the reverse is a violation, and a decimal against a double raises.
# - test_a_decimal_column_is_recorded_and_read_back: format_reference and
#   parse_references keep the decimal statistics, the result compares
#   identical, writing it again gives the same text, and a sum or bound that is
#   not canonical is refused.
# - test_json_columns_are_read_by_their_types: the same quoted value is a
#   decimal in a DECIMAL column, an integer or a decimal in a HUGEINT column, a
#   text in a VARCHAR column and in an untyped read; a wrong number of types is
#   refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    Cell,
    ExactSum,
    OrderKey,
    REFERENCE_FORMAT,
    ReferenceAnswer,
    ResultSet,
    canonical_decimal,
    check_order,
    compare_decimals,
    compare_signatures,
    exactness_of_type,
    format_reference,
    parse_json_rows,
    parse_references,
    signature_of,
)
from komira_bench_duckdb.cells import KIND_DECIMAL, KIND_FLOAT, KIND_INT, KIND_TEXT


def _refuses_decimal(text: String) -> Bool:
    try:
        _ = canonical_decimal(text)
    except:
        return True
    return False


def test_decimal_text_has_one_canonical_form() raises:
    assert_equal(canonical_decimal(String("123.40")), String("123.4"))
    assert_equal(canonical_decimal(String("123.4")), String("123.4"))
    assert_equal(canonical_decimal(String("0123.4")), String("123.4"))
    assert_equal(canonical_decimal(String("123.400")), String("123.4"))
    assert_equal(canonical_decimal(String("-0.0")), String("0"))
    assert_equal(canonical_decimal(String("0.000")), String("0"))
    assert_equal(canonical_decimal(String("000")), String("0"))
    assert_equal(canonical_decimal(String("-12.50")), String("-12.5"))
    assert_equal(canonical_decimal(String("-0.05")), String("-0.05"))
    assert_equal(canonical_decimal(String("100")), String("100"))
    var widest = String("0.12345678901234567890123456789012345678")
    assert_equal(canonical_decimal(widest), widest)
    assert_equal(canonical_decimal(widest + String("0")), widest)
    assert_true(_refuses_decimal(widest + String("9")))
    assert_true(_refuses_decimal(String("")))
    assert_true(_refuses_decimal(String("-")))
    assert_true(_refuses_decimal(String(".5")))
    assert_true(_refuses_decimal(String("1.")))
    assert_true(_refuses_decimal(String("1e5")))
    assert_true(_refuses_decimal(String("+1")))
    assert_true(_refuses_decimal(String("1.2.3")))
    assert_true(_refuses_decimal(String("12x")))
    assert_true(_refuses_decimal(String("--1")))
    assert_true(_refuses_decimal(String("NaN")))


def test_decimals_are_ordered_by_value() raises:
    var ascending = List[String]()
    var parts = String(
        "-10 -9.5 -0.5 -0.05 0 0.05 0.5 1 9.5 10 10.25 100 99999999999999999999999999999999999999"
    ).split(" ")
    for i in range(len(parts)):
        ascending.append(String(parts[i]))
    for i in range(len(ascending)):
        for j in range(len(ascending)):
            var want = 0
            if i < j:
                want = -1
            elif i > j:
                want = 1
            assert_equal(compare_decimals(ascending[i], ascending[j]), want, ascending[i] + " against " + ascending[j])
    assert_equal(compare_decimals(String("1.50"), String("1.5")), 0)
    assert_equal(compare_decimals(String("-0"), String("0.0")), 0)


def _sum_of(terms: List[String]) raises -> String:
    var s = ExactSum()
    for i in range(len(terms)):
        s.add(terms[i])
    return s.text()


def test_exact_sums_do_not_round_and_do_not_overflow() raises:
    var none = List[String]()
    assert_equal(_sum_of(none), String("0"))
    var carry = List[String]()
    carry.append(String("999999999999999999.999999999999999999"))
    carry.append(String("0.000000000000000001"))
    assert_equal(_sum_of(carry), String("1000000000000000000"))
    # 4 x (10^38 - 1) does not fit 128 bits
    var nines = String("99999999999999999999999999999999999999")
    var big = List[String]()
    for _ in range(4):
        big.append(nines)
    assert_equal(_sum_of(big), String("399999999999999999999999999999999999996"))
    var cancel = List[String]()
    cancel.append(String("12.5"))
    cancel.append(String("-12.50"))
    assert_equal(_sum_of(cancel), String("0"))
    var flip = List[String]()
    flip.append(String("1"))
    flip.append(String("-3.25"))
    assert_equal(_sum_of(flip), String("-2.25"))
    flip.append(String("2.25"))
    assert_equal(_sum_of(flip), String("0"))
    var tiny = List[String]()
    var one_unit = String("0.00000000000000000000000000000000000001")
    tiny.append(one_unit)
    tiny.append(one_unit)
    assert_equal(_sum_of(tiny), String("0.00000000000000000000000000000000000002"))
    # the order of the terms does not matter
    var a = List[String]()
    a.append(String("123141078.2283"))
    a.append(String("-0.0001"))
    a.append(String("77"))
    a.append(String("-123141000.1"))
    var b = List[String]()
    b.append(String("-123141000.1"))
    b.append(String("77"))
    b.append(String("123141078.2283"))
    b.append(String("-0.0001"))
    assert_equal(_sum_of(a), _sum_of(b))
    assert_equal(_sum_of(a), String("155.1282"))


def test_a_decimal_cell_is_canonical_and_refuses_bad_text() raises:
    var c = Cell.decimal(String("123.40"))
    assert_equal(c.kind, KIND_DECIMAL)
    assert_equal(c.s, String("123.4"))
    var raised = False
    try:
        _ = Cell.decimal(String("12x"))
    except:
        raised = True
    assert_true(raised)


def _column(values: List[String]) raises -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    for i in range(len(values)):
        var row = List[Cell]()
        row.append(Cell.decimal(values[i]))
        rs.add_row(row^)
    return rs^


def _strings(a: String, b: String, c: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _reason(a: ResultSet, b: ResultSet) raises -> String:
    var v = compare_signatures(signature_of(a), signature_of(b))
    if v.identical:
        return String("")
    return v.reasons[0].copy()


def test_a_decimal_column_signature_is_exact_and_order_independent() raises:
    var base = _column(_strings(String("123141078.2283"), String("0.5"), String("-7.25")))
    var shuffled = _column(_strings(String("-7.25"), String("123141078.2283"), String("0.50")))
    assert_equal(_reason(base, shuffled), String(""))
    var sig = signature_of(base)
    assert_equal(sig.columns[0].kind(), KIND_DECIMAL)
    assert_equal(sig.columns[0].count, 3)
    assert_equal(sig.columns[0].dsum.text(), String("123141071.4783"))
    assert_equal(sig.columns[0].dmin, String("-7.25"))
    assert_equal(sig.columns[0].dmax, String("123141078.2283"))
    var last_digit = _column(_strings(String("123141078.2284"), String("0.5"), String("-7.25")))
    assert_true(_reason(base, last_digit).find(String("sum differs")) >= 0)
    # the same sum from other cells is still another answer
    var moved = _column(_strings(String("123141078.2284"), String("0.4999"), String("-7.25")))
    var r = compare_signatures(signature_of(base), signature_of(moved))
    assert_false(r.identical)
    var fewer = _column(_strings(String("123141078.2283"), String("-6.75")))
    assert_true(_reason(base, fewer).find(String("count differs")) >= 0)


def _wide_and_small(small: Int64, wide: String) raises -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    var a = List[Cell]()
    a.append(Cell.integer(small))
    rs.add_row(a^)
    var b = List[Cell]()
    b.append(Cell.decimal(wide))
    rs.add_row(b^)
    return rs^


def test_integers_among_decimals_are_compared_as_integers() raises:
    var wide = String("18446744073709551615")
    var x = _wide_and_small(Int64(5), wide)
    assert_equal(signature_of(x).columns[0].kind(), KIND_DECIMAL)
    assert_equal(_reason(x, _wide_and_small(Int64(5), wide)), String(""))
    assert_true(_reason(x, _wide_and_small(Int64(6), wide)).find(String("integer sum")) >= 0)
    assert_true(_reason(x, _wide_and_small(Int64(5), String("18446744073709551614"))).find(String("sum differs")) >= 0)


def test_a_decimal_column_does_not_compare_with_other_kinds() raises:
    var d = _column(_strings(String("1.5"), String("2")))
    var ints = ResultSet()
    ints.names.append(String("v"))
    var floats = ResultSet()
    floats.names.append(String("v"))
    var texts = ResultSet()
    texts.names.append(String("v"))
    for i in range(2):
        var a = List[Cell]()
        a.append(Cell.integer(Int64(i + 1)))
        ints.add_row(a^)
        var b = List[Cell]()
        b.append(Cell.real(Float64(i) + 1.5 if i == 0 else 2.0))
        floats.add_row(b^)
        var c = List[Cell]()
        c.append(Cell.text(String("1.5") if i == 0 else String("2")))
        texts.add_row(c^)
    for other in [ints.copy(), floats.copy(), texts.copy()]:
        var forward = _reason(d, other)
        var backward = _reason(other, d)
        assert_true(forward.find(String("has kind")) >= 0, forward)
        assert_true(backward.find(String("has kind")) >= 0, backward)
        assert_true(forward.find(String("exact decimal")) >= 0, forward)
    assert_true(_reason(d, floats).find(String("double")) >= 0)
    # decimals and doubles in one column have no signature to compare
    var mixed = ResultSet()
    mixed.names.append(String("v"))
    var m1 = List[Cell]()
    m1.append(Cell.decimal(String("1.5")))
    mixed.add_row(m1^)
    var m2 = List[Cell]()
    m2.append(Cell.real(1.5))
    mixed.add_row(m2^)
    var verdict = compare_signatures(signature_of(mixed), signature_of(mixed))
    assert_false(verdict.identical)
    var raised = False
    try:
        var ans = ReferenceAnswer(String("m"))
        ans.signature = signature_of(mixed)
        _ = format_reference(ans)
    except:
        raised = True
    assert_true(raised)


def test_the_row_order_check_orders_decimals_by_value() raises:
    var keys = List[OrderKey]()
    keys.append(OrderKey(0))
    assert_true(check_order(_column(_strings(String("9.5"), String("10.25"), String("10.250"))), keys).ok)
    assert_false(check_order(_column(_strings(String("10.25"), String("9.5"))), keys).ok)
    var down = List[OrderKey]()
    down.append(OrderKey(0, True))
    assert_true(check_order(_column(_strings(String("10.25"), String("9.5"))), down).ok)
    assert_false(check_order(_column(_strings(String("9.5"), String("10.25"))), down).ok)
    var with_float = ResultSet()
    with_float.names.append(String("v"))
    var a = List[Cell]()
    a.append(Cell.decimal(String("1.5")))
    with_float.add_row(a^)
    var b = List[Cell]()
    b.append(Cell.real(2.5))
    with_float.add_row(b^)
    var raised = False
    try:
        _ = check_order(with_float, keys)
    except:
        raised = True
    assert_true(raised)


def test_a_decimal_column_is_recorded_and_read_back() raises:
    var rs = _wide_and_small(Int64(-3), String("18446744073709551615"))
    var row = List[Cell]()
    row.append(Cell.decimal(String("0.00000000000000000000000000000000000001")))
    rs.add_row(row^)
    var ans = ReferenceAnswer(String("q"))
    ans.signature = signature_of(rs)
    var text = format_reference(ans)
    assert_true(text.startswith(String("format ") + String(REFERENCE_FORMAT) + String("\n")))
    var back = parse_references(text).answers[0].copy()
    assert_equal(back.signature.columns[0].kind(), KIND_DECIMAL)
    assert_equal(back.signature.columns[0].dcount, 2)
    assert_true(compare_signatures(signature_of(rs), back.signature).identical)
    assert_equal(format_reference(back), text)
    # another last digit of a recorded value is no longer the same answer
    var other = _wide_and_small(Int64(-3), String("18446744073709551614"))
    var row2 = List[Cell]()
    row2.append(Cell.decimal(String("0.00000000000000000000000000000000000001")))
    other.add_row(row2^)
    assert_false(compare_signatures(signature_of(other), back.signature).identical)
    # a sum or a bound written in a non-canonical way is refused
    var lines = text.split(String("\n"))
    var bent = String("")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.startswith(String("column ")):
            line = line.replace(String(" 18446744073709551615 "), String(" 18446744073709551615.0 "))
        bent += line + String("\n")
    var raised = False
    try:
        _ = parse_references(bent)
    except:
        raised = True
    assert_true(raised, "a bound written 18446744073709551615.0 is not canonical")


def test_json_columns_are_read_by_their_types() raises:
    var json = String('[{"d":"123.40","h":"9223372036854775807","u":"18446744073709551615","v":"1994"}]')
    var types = List[String]()
    types.append(String("DECIMAL(10,2)"))
    types.append(String("HUGEINT"))
    types.append(String("UBIGINT"))
    types.append(String("VARCHAR"))
    var typed = parse_json_rows(json, types)
    assert_equal(typed.rows[0][0].kind, KIND_DECIMAL)
    assert_equal(typed.rows[0][0].s, String("123.4"))
    assert_equal(typed.rows[0][1].kind, KIND_INT)
    assert_equal(typed.rows[0][2].kind, KIND_DECIMAL)
    assert_equal(typed.rows[0][2].s, String("18446744073709551615"))
    assert_equal(typed.rows[0][3].kind, KIND_TEXT)
    assert_equal(typed.rows[0][3].s, String("1994"))
    var untyped = parse_json_rows(json)
    for c in range(4):
        assert_equal(untyped.rows[0][c].kind, KIND_TEXT)
    var short = List[String]()
    short.append(String("DECIMAL(10,2)"))
    var raised = False
    try:
        _ = parse_json_rows(json, short)
    except:
        raised = True
    assert_true(raised, "one type for four columns")
    # a bare number in an exact column is read exactly too, and null is null
    var bare = parse_json_rows(String('[{"d":5,"n":null}]'), _strings(String("DECIMAL(3,0)"), String("DECIMAL(3,0)")))
    assert_equal(bare.rows[0][0].kind, KIND_DECIMAL)
    assert_equal(bare.rows[0][0].s, String("5"))
    assert_true(bare.rows[0][1].is_null())
    assert_equal(exactness_of_type(String("DECIMAL(38,4)")), 1)
    assert_equal(exactness_of_type(String("HUGEINT")), 2)
    assert_equal(exactness_of_type(String("UHUGEINT")), 2)
    assert_equal(exactness_of_type(String("UBIGINT")), 2)
    assert_equal(exactness_of_type(String("BIGINT")), 0)
    assert_equal(exactness_of_type(String("DOUBLE")), 0)
    assert_equal(exactness_of_type(String("VARCHAR")), 0)
    assert_equal(exactness_of_type(String("DECIMAL(3,1)[]")), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
