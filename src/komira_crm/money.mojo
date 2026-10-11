# =============================================================================
# komira_crm/money.mojo -- ISO 4217 currency codes and exact amounts.
# =============================================================================
#
# A deal's amount is an integer count of its currency's minor unit
# (`amount_minor`), with the ISO 4217 alphabetic code beside it. The store
# carries the codes of ISO 4217 List One (the edition published 2026-09-17
# by the maintenance agency) that have a minor unit, each with its number of
# minor-unit digits: 0 (JPY), 2 (EUR), 3 (BHD) or 4 (CLF). The codes whose
# minor unit is "N.A." (precious metals, bond-market units, the SDR, XSU,
# XUA, the testing code XTS and XXX) are not carried: an amount in them has
# no minor unit to count, so they are refused like an unknown code.
#
#   minor_unit_digits(code)    the digits, or -1 for a code not carried
#   check_currency(code)       refuses a code not carried
#   parse_amount(text, code)   a decimal in major units ("12.34") to minor
#                              units (1234), refusing a value that is not a
#                              whole number of minor units ("12.345" USD,
#                              "1.5" JPY)
# =============================================================================

from komira_crm.errors import ERR_FRACTIONAL_AMOUNT, ERR_UNKNOWN_CURRENCY, invalid

# Four bytes per code: the code, then its minor-unit digits. Sorted.
comptime _TABLE: StaticString = (
    "AED2AFN2ALL2AMD2AOA2ARS2AUD2AWG2AZN2BAM2BBD2BDT2BHD3BIF0BMD2BND2BOB2BOV2BRL2BSD2BTN2BWP2"
    "BYN2BZD2CAD2CDF2CHE2CHF2CHW2CLF4CLP0CNY2COP2COU2CRC2CUP2CVE2CZK2DJF0DKK2DOP2DZD2EGP2ERN2"
    "ETB2EUR2FJD2FKP2GBP2GEL2GHS2GIP2GMD2GNF0GTQ2GYD2HKD2HNL2HTG2HUF2IDR2ILS2INR2IQD3IRR2ISK0"
    "JMD2JOD3JPY0KES2KGS2KHR2KMF0KPW2KRW0KWD3KYD2KZT2LAK2LBP2LKR2LRD2LSL2LYD3MAD2MDL2MGA2MKD2"
    "MMK2MNT2MOP2MRU2MUR2MVR2MWK2MXN2MXV2MYR2MZN2NAD2NGN2NIO2NOK2NPR2NZD2OMR3PAB2PEN2PGK2PHP2"
    "PKR2PLN2PYG0QAR2RON2RSD2RUB2RWF0SAR2SBD2SCR2SDG2SEK2SGD2SHP2SLE2SOS2SRD2SSP2STN2SVC2SYP2"
    "SZL2THB2TJS2TMT2TND3TOP2TRY2TTD2TWD2TZS2UAH2UGX0USD2USN2UYI0UYU2UYW4UZS2VED2VES2VND0VUV0"
    "WST2XAD2XAF0XCD2XCG2XOF0XPF0YER2ZAR2ZMW2ZWG2")
comptime CURRENCY_COUNT = 165


def minor_unit_digits(code: String) -> Int:
    """The number of minor-unit digits of ISO 4217 `code`, or -1 when the
    store does not carry it (unknown, withdrawn, lower case, or without a
    minor unit)."""
    var c = code.as_bytes()
    if len(c) != 3:
        return -1
    var t = _TABLE.as_bytes()
    for i in range(CURRENCY_COUNT):
        var at = i * 4
        if t[at] == c[0] and t[at + 1] == c[1] and t[at + 2] == c[2]:
            return Int(t[at + 3]) - 48
    return -1


def check_currency(code: String) raises:
    if minor_unit_digits(code) < 0:
        raise Error(String(ERR_UNKNOWN_CURRENCY))


def parse_amount(text: String, code: String) raises -> Int64:
    """`text` (decimal digits, optionally a `.` and more digits, no sign) in
    the major unit of currency `code`, as a count of its minor unit. Digits
    past the currency's minor unit must be zeros."""
    var digits = minor_unit_digits(code)
    if digits < 0:
        raise Error(String(ERR_UNKNOWN_CURRENCY))
    var b = text.as_bytes()
    var out = Int64(0)
    var seen_digit = False
    var dot = False
    var frac = 0
    for i in range(len(b)):
        var ch = b[i]
        if ch == UInt8(ord(".")) and not dot and seen_digit:
            dot = True
            continue
        if ch < UInt8(ord("0")) or ch > UInt8(ord("9")):
            raise invalid("amount", "not a decimal number")
        var d = Int64(Int(ch) - 48)
        if dot:
            frac += 1
            if frac > digits:
                if d != 0:
                    raise Error(String(ERR_FRACTIONAL_AMOUNT))
                continue
        if out > (Int64.MAX - d) // 10:
            raise invalid("amount", "too large")
        out = out * 10 + d
        seen_digit = True
    if not seen_digit or (dot and frac == 0):
        raise invalid("amount", "not a decimal number")
    while frac < digits:
        if out > Int64.MAX // 10:
            raise invalid("amount", "too large")
        out *= 10
        frac += 1
    return out


def check_money(amount_minor: Int64, currency: String) raises:
    """An amount is not negative, and has a carried currency unless it is 0
    (a deal with no amount)."""
    if amount_minor < 0:
        raise invalid("amountMinor", "must not be negative")
    if currency.byte_length() == 0:
        if amount_minor != 0:
            raise invalid("currency", "required when amountMinor is not 0")
        return
    check_currency(currency)
