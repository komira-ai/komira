# =============================================================================
# test_excel_error_code.mojo: the Excel error-code space, every member.
# =============================================================================
#
# `excel_error_code.mojo` declares ten codes (`XL_ERR_NONE` = 0 through
# `XL_ERR_CALC` = 9), and the plan wire publishes the same ten
# (`ExcelErrorCode`, wire = code + 1). This file holds both helpers that turn a
# code into what a user sees and back, for every member:
#
#   excel_error_text(code)              code -> display spelling
#   excel_error_code_from_literal(text) spelling written in a formula -> code
#
# THE EXPECTED SPELLINGS ARE EXCEL'S, NOT THE CODE'S. Microsoft documents
# `#NULL!`, `#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`, `#N/A` (and
# `#GETTING_DATA`) as the ERROR.TYPE values; OpenFormula defines the first
# seven only. `#SPILL!` and `#CALC!` are the dynamic-array errors. Each is written below as
# a literal, so changing a spelling in the code is a change to this table.
#
# ONE CODE HAS NO EXCEL LITERAL, and the table says so rather than skipping
# it: XL_ERR_NONE is "not an error". It renders as the unrecognised-code
# fallback `#ERR?`, which parses back as `#NAME?`. The round trip below
# excludes it on purpose and pins what it does instead.
#
# EVERY OTHER CODE IS ONE OF MICROSOFT'S. There is no circular-reference code:
# Excel reports a circular reference as a warning, not as an error value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.excel_error_code import (
    XL_ERR_NONE,
    XL_ERR_DIV0,
    XL_ERR_NA,
    XL_ERR_VALUE,
    XL_ERR_REF,
    XL_ERR_NAME,
    XL_ERR_NUM,
    XL_ERR_NULL,
    XL_ERR_SPILL,
    XL_ERR_CALC,
    EXCEL_ERROR_CODE_LAST,
    excel_error_text,
    excel_error_code_from_literal,
)


@fieldwise_init
struct _Row(Copyable, Movable, ImplicitlyCopyable):
    var code: UInt8
    var name: String
    var text: String
    var has_literal: Bool


def _table() -> List[_Row]:
    """The ten codes, in code order, each with the spelling Excel uses."""
    var t = List[_Row]()
    t.append(_Row(XL_ERR_NONE, String("XL_ERR_NONE"), String("#ERR?"), False))
    t.append(_Row(XL_ERR_DIV0, String("XL_ERR_DIV0"), String("#DIV/0!"), True))
    t.append(_Row(XL_ERR_NA, String("XL_ERR_NA"), String("#N/A"), True))
    t.append(_Row(XL_ERR_VALUE, String("XL_ERR_VALUE"), String("#VALUE!"), True))
    t.append(_Row(XL_ERR_REF, String("XL_ERR_REF"), String("#REF!"), True))
    t.append(_Row(XL_ERR_NAME, String("XL_ERR_NAME"), String("#NAME?"), True))
    t.append(_Row(XL_ERR_NUM, String("XL_ERR_NUM"), String("#NUM!"), True))
    t.append(_Row(XL_ERR_NULL, String("XL_ERR_NULL"), String("#NULL!"), True))
    t.append(_Row(XL_ERR_SPILL, String("XL_ERR_SPILL"), String("#SPILL!"), True))
    t.append(_Row(XL_ERR_CALC, String("XL_ERR_CALC"), String("#CALC!"), True))
    return t^


def test_the_table_is_the_whole_space_in_code_order() raises:
    """The table holds ten rows and row i is code i, so every test below
    walks every code; and the last row is `EXCEL_ERROR_CODE_LAST`, the bound
    the pplan codec range-checks against. Without this, a table that skipped a
    code would leave it untested and every assertion would still pass."""
    var t = _table()
    assert_equal(len(t), 10, "the space has ten codes, NONE through CALC")
    assert_equal(
        Int(EXCEL_ERROR_CODE_LAST), len(t) - 1,
        "EXCEL_ERROR_CODE_LAST is not the last code of the space",
    )
    for i in range(len(t)):
        assert_equal(
            Int(t[i].code), i,
            t[i].name + " is not code " + String(i) + "; the space is dense"
            + " from 0, and the wire maps code c to c + 1",
        )


def test_every_code_renders_its_excel_spelling() raises:
    """`excel_error_text` for each of the ten codes. Catches a swapped or
    misspelled arm (`#DIV/0` without `!`, `#NAME!` for `#NAME?`)."""
    var t = _table()
    for i in range(len(t)):
        assert_equal(
            excel_error_text(t[i].code), t[i].text,
            "excel_error_text(" + t[i].name + ")",
        )


def test_codes_outside_the_space_render_the_fallback() raises:
    """One past CALC (10, which was a circular-reference code and is not one
    any more), 11, and the top of a UInt8 are not codes; all render the
    fallback rather than some member's text."""
    assert_equal(excel_error_text(UInt8(10)), "#ERR?")
    assert_equal(excel_error_text(UInt8(11)), "#ERR?")
    assert_equal(excel_error_text(UInt8(255)), "#ERR?")


def test_the_spellings_are_distinct() raises:
    """Two codes with one spelling would make the display ambiguous and the
    literal round trip lossy."""
    var t = _table()
    for i in range(len(t)):
        for j in range(i + 1, len(t)):
            assert_true(
                excel_error_text(t[i].code) != excel_error_text(t[j].code),
                t[i].name + " and " + t[j].name + " render the same text",
            )


def test_every_excel_literal_parses_to_its_code() raises:
    """`excel_error_code_from_literal` for each of the nine codes Excel has a
    literal for. `#SPILL!` and `#CALC!` are the two a formula layer meets from
    dynamic arrays; parsing either as `#NAME?` would turn one error into
    another."""
    var t = _table()
    var checked = 0
    for i in range(len(t)):
        if not t[i].has_literal:
            continue
        assert_equal(
            Int(excel_error_code_from_literal(t[i].text)), Int(t[i].code),
            "excel_error_code_from_literal(\"" + t[i].text + "\") should be "
            + t[i].name,
        )
        checked += 1
    assert_equal(checked, 9, "nine codes have an Excel literal")


def test_literal_to_code_to_text_round_trips() raises:
    """literal -> code -> text returns the literal, for every literal. This is
    the property the shared code space promises: a formula's error literal
    survives the trip through the engine as the same error."""
    var t = _table()
    for i in range(len(t)):
        if not t[i].has_literal:
            continue
        var code = excel_error_code_from_literal(t[i].text)
        assert_equal(
            excel_error_text(code), t[i].text,
            "\"" + t[i].text + "\" -> code " + String(Int(code)) + " -> text",
        )


def test_the_code_without_a_literal_parses_as_name() raises:
    """NONE renders text that is not an Excel literal, so parsing that text
    gives `#NAME?`, the code for an unknown `#token`. Pinned so that giving it
    a literal is a deliberate change to this test."""
    assert_equal(
        Int(excel_error_code_from_literal(excel_error_text(XL_ERR_NONE))),
        Int(XL_ERR_NAME),
    )


def test_unknown_tokens_parse_as_name() raises:
    """An unknown `#token` is a name error. `#GETTING_DATA` and `#BLOCKED!`
    are Excel error values this code space does not declare, so they land
    here too; adding them is a change to the wire vocabulary as well."""
    assert_equal(Int(excel_error_code_from_literal(String("#FOO!"))), Int(XL_ERR_NAME))
    assert_equal(Int(excel_error_code_from_literal(String("#GETTING_DATA"))), Int(XL_ERR_NAME))
    assert_equal(Int(excel_error_code_from_literal(String("#BLOCKED!"))), Int(XL_ERR_NAME))


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_table_is_the_whole_space_in_code_order]()
    suite.test[test_every_code_renders_its_excel_spelling]()
    suite.test[test_codes_outside_the_space_render_the_fallback]()
    suite.test[test_the_spellings_are_distinct]()
    suite.test[test_every_excel_literal_parses_to_its_code]()
    suite.test[test_literal_to_code_to_text_round_trips]()
    suite.test[test_the_code_without_a_literal_parses_as_name]()
    suite.test[test_unknown_tokens_parse_as_name]()
    suite^.run()
