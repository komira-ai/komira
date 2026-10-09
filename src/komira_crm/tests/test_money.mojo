# =============================================================================
# test_money.mojo -- ISO 4217 codes and exact amounts (money.mojo).
# =============================================================================
#
# THE CODE CENSUS. `_ISO_4217` below restates, literally, every code of ISO
# 4217 List One (published 2026-09-17) whose minor unit is a number, with
# that number. Every one must map to its digits, and every other string of
# three capital letters (all 17,576 are tried) must be refused: that catches
# a code dropped from or added to the table, a wrong digit count, and a scan
# that stops early. The codes whose minor unit is "N.A." (XAU, XDR, XTS,
# XXX, ...) and withdrawn codes (ANG, HRK, SLL) are refused by name too.
#
# AMOUNTS. `parse_amount` turns a decimal in major units into minor units:
# each vector names the defect it catches (a digit past the minor unit
# accepted, a trailing zero refused, a scale off by one, an overflow
# wrapped). Refusals are compared by their exact text.
# =============================================================================

from std.testing import assert_equal

from komira_crm import (
    CURRENCY_COUNT,
    ERR_FRACTIONAL_AMOUNT,
    ERR_UNKNOWN_CURRENCY,
    check_currency,
    check_money,
    minor_unit_digits,
    parse_amount,
)

comptime OK = "ok"
comptime NOT_DECIMAL = "crm: invalid amount: not a decimal number"
comptime TOO_LARGE = "crm: invalid amount: too large"

comptime _ISO_4217: StaticString = (
    "AED 2 AFN 2 ALL 2 AMD 2 AOA 2 ARS 2 AUD 2 AWG 2 AZN 2 BAM 2 BBD 2 BDT 2 BHD 3 BIF 0 "
    "BMD 2 BND 2 BOB 2 BOV 2 BRL 2 BSD 2 BTN 2 BWP 2 BYN 2 BZD 2 CAD 2 CDF 2 CHE 2 CHF 2 "
    "CHW 2 CLF 4 CLP 0 CNY 2 COP 2 COU 2 CRC 2 CUP 2 CVE 2 CZK 2 DJF 0 DKK 2 DOP 2 DZD 2 "
    "EGP 2 ERN 2 ETB 2 EUR 2 FJD 2 FKP 2 GBP 2 GEL 2 GHS 2 GIP 2 GMD 2 GNF 0 GTQ 2 GYD 2 "
    "HKD 2 HNL 2 HTG 2 HUF 2 IDR 2 ILS 2 INR 2 IQD 3 IRR 2 ISK 0 JMD 2 JOD 3 JPY 0 KES 2 "
    "KGS 2 KHR 2 KMF 0 KPW 2 KRW 0 KWD 3 KYD 2 KZT 2 LAK 2 LBP 2 LKR 2 LRD 2 LSL 2 LYD 3 "
    "MAD 2 MDL 2 MGA 2 MKD 2 MMK 2 MNT 2 MOP 2 MRU 2 MUR 2 MVR 2 MWK 2 MXN 2 MXV 2 MYR 2 "
    "MZN 2 NAD 2 NGN 2 NIO 2 NOK 2 NPR 2 NZD 2 OMR 3 PAB 2 PEN 2 PGK 2 PHP 2 PKR 2 PLN 2 "
    "PYG 0 QAR 2 RON 2 RSD 2 RUB 2 RWF 0 SAR 2 SBD 2 SCR 2 SDG 2 SEK 2 SGD 2 SHP 2 SLE 2 "
    "SOS 2 SRD 2 SSP 2 STN 2 SVC 2 SYP 2 SZL 2 THB 2 TJS 2 TMT 2 TND 3 TOP 2 TRY 2 TTD 2 "
    "TWD 2 TZS 2 UAH 2 UGX 0 USD 2 USN 2 UYI 0 UYU 2 UYW 4 UZS 2 VED 2 VES 2 VND 0 VUV 0 "
    "WST 2 XAD 2 XAF 0 XCD 2 XCG 2 XOF 0 XPF 0 YER 2 ZAR 2 ZMW 2 ZWG 2 ")


def _expected(code: String) -> Int:
    """The digits `_ISO_4217` gives `code`, or -1."""
    var t = _ISO_4217.as_bytes()
    var c = code.as_bytes()
    var i = 0
    while i + 5 < len(t):
        if t[i] == c[0] and t[i + 1] == c[1] and t[i + 2] == c[2]:
            return Int(t[i + 4]) - 48
        i += 6
    return -1


def test_census() raises:
    var listed = 0
    for a in range(26):
        for b in range(26):
            for c in range(26):
                var code = String(chr(65 + a)) + chr(65 + b) + chr(65 + c)
                var want = _expected(code)
                if want >= 0:
                    listed += 1
                assert_equal(minor_unit_digits(code), want, code)
    assert_equal(listed, 165, "the restated list has 165 codes")
    assert_equal(CURRENCY_COUNT, 165)


def _refused(code: String) -> String:
    try:
        check_currency(String(code))
        return String(OK)
    except e:
        return String(e)


def test_refused_codes() raises:
    assert_equal(_refused("EUR"), OK)
    assert_equal(_refused("ZWG"), OK, "the last code of the table")
    assert_equal(_refused("AED"), OK, "the first code of the table")
    for code in ["XAU", "XAG", "XDR", "XTS", "XXX", "XSU", "XUA", "XBA", "ANG", "HRK", "SLL"]:
        assert_equal(_refused(code), ERR_UNKNOWN_CURRENCY, code)
    for code in ["usd", "US", "USDX", "", "U$D"]:
        assert_equal(_refused(code), ERR_UNKNOWN_CURRENCY, code)


def _amount(text: String, code: String) -> String:
    try:
        return String(parse_amount(String(text), String(code)))
    except e:
        return String(e)


def test_amounts() raises:
    assert_equal(_amount("12.34", "USD"), "1234")
    assert_equal(_amount("12", "USD"), "1200", "whole units are scaled")
    assert_equal(_amount("0.5", "USD"), "50", "one fraction digit is scaled")
    assert_equal(_amount("12.340", "USD"), "1234", "a zero past the minor unit is exact")
    assert_equal(_amount("12.345", "USD"), ERR_FRACTIONAL_AMOUNT, "a third digit of cents")
    assert_equal(_amount("0.001", "USD"), ERR_FRACTIONAL_AMOUNT)
    assert_equal(_amount("7", "JPY"), "7", "no minor unit: no scaling")
    assert_equal(_amount("1.0", "JPY"), "1")
    assert_equal(_amount("1.5", "JPY"), ERR_FRACTIONAL_AMOUNT, "a yen has no fraction")
    assert_equal(_amount("0.001", "BHD"), "1", "three digits")
    assert_equal(_amount("1.0001", "BHD"), ERR_FRACTIONAL_AMOUNT)
    assert_equal(_amount("1.2345", "CLF"), "12345", "four digits")
    assert_equal(_amount("1.23456", "CLF"), ERR_FRACTIONAL_AMOUNT)
    assert_equal(_amount("12.34", "XAU"), ERR_UNKNOWN_CURRENCY, "no minor unit to count")
    assert_equal(_amount("12.34", "usd"), ERR_UNKNOWN_CURRENCY)
    for text in ["", ".5", "5.", "1.2.3", "-1", "+1", "1e3", " 1", "1,000", "1.", "."]:
        assert_equal(_amount(text, "USD"), NOT_DECIMAL, text)


def test_amount_limits() raises:
    assert_equal(_amount("92233720368547758.07", "USD"), "9223372036854775807", "Int64.MAX cents")
    assert_equal(_amount("92233720368547758.08", "USD"), TOO_LARGE, "one cent over")
    assert_equal(_amount("92233720368547759", "USD"), TOO_LARGE, "overflows when scaled")
    assert_equal(_amount("92233720368547758", "USD"), "9223372036854775800", "the largest whole amount")
    assert_equal(_amount("9223372036854775807", "JPY"), "9223372036854775807")
    assert_equal(_amount("9223372036854775808", "JPY"), TOO_LARGE)
    assert_equal(_amount("00000000000000000000000000012", "JPY"), "12", "leading zeros")


def _money(amount: Int64, code: StaticString) -> String:
    try:
        check_money(amount, String(code))
        return String(OK)
    except e:
        return String(e)


def test_check_money() raises:
    assert_equal(_money(0, ""), OK, "no amount needs no currency")
    assert_equal(_money(1, ""), "crm: invalid currency: required when amountMinor is not 0")
    assert_equal(_money(-1, "USD"), "crm: invalid amountMinor: must not be negative")
    assert_equal(_money(0, "USD"), OK)
    assert_equal(_money(100, "XXX"), ERR_UNKNOWN_CURRENCY)
    assert_equal(_money(Int64.MAX, "KWD"), OK)


def main() raises:
    test_census()
    test_refused_codes()
    test_amounts()
    test_amount_limits()
    test_check_money()
    print("PASS komira_crm test_money")
