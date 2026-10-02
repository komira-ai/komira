# =============================================================================
# xl_scalar_ref.mojo — ★ THE SCALAR-REACHABLE CORNER OF EXCEL'S **LOOKUP AND
#                        REFERENCE** CATEGORY (2026-09-14).
# =============================================================================
#
# ⛔⛔ MOST OF THAT CATEGORY IS NOT SCALAR AND IS NOT HERE, AND THE BOUNDARY IS
# THE POINT OF THIS FILE'S EXISTENCE RATHER THAN AN APOLOGY FOR ITS SIZE.
# `FormulaValue` carries number / text / logical / blank / error and NOTHING
# array- or reference-shaped. So:
#
#   * a function whose ARGUMENT is a reference — `ROW(ref)`, `COLUMN(ref)`,
#     `ROWS`, `COLUMNS`, `AREAS`, `FORMULATEXT`, `OFFSET`, `INDIRECT` — cannot
#     be CALLED here. There is no value to pass it.
#   * a function whose RESULT is an array — `TRANSPOSE`, `WRAPROWS`,
#     `WRAPCOLS`, `DROP`, `EXPAND`, `CHOOSEROWS`, `TOROW`, `TOCOL` — cannot
#     RETURN through this door. There is no value to return.
#   * `ROW()` / `COLUMN()` with NO argument need the CALLING CELL's own
#     coordinates, which a ctx-free evaluator of a bare formula string does not
#     have and must not invent.
#
# Each of those is written into `xl_absent_common_names()` with that reason, so
# a caller asking the census gets `no, and here is why` instead of silence.
#
# ⭐ WHAT IS LEFT IS GENUINELY SCALAR, AND IT IS NOT NOTHING. `ADDRESS` takes
# NUMBERS and returns TEXT — it is a reference *formatter*, not a reference —
# and `HYPERLINK`'s VALUE is its friendly name. Both are complete functions
# here, not stubs.
#
# Encapsulation rule : values only. No `UnsafePointer`.
# =============================================================================

from komira_core.plan.excel_error_code import XL_ERR_VALUE

from .formula_value import FormulaValue


comptime _XL_MAX_ROW: Int = 1048576
"""Excel's worksheet row ceiling. `ADDRESS` past it is `#VALUE!` — a refusal,
because the alternative is formatting an address that cannot exist."""

comptime _XL_MAX_COL: Int = 16384
"""Excel's worksheet column ceiling — column `XFD`."""


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _col_letters(col: Int) -> String:
    """A 1-based column number as Excel's letters.

    ⛔⛔ IT IS **BIJECTIVE** BASE-26, NOT BASE-26, AND THAT IS THE ONE THING
    THIS FUNCTION EXISTS TO GET RIGHT. There is no zero digit: 26 is `Z`, 27 is
    `AA`, 702 is `ZZ` and 703 is `AAA`. The natural `chr(65 + n % 26)` loop —
    which is what a reader writes from memory — produces `AB` for 27 and `A@`
    for 26, and it is CORRECT for every column from 1 to 25, so an A..Z fixture
    cannot see the defect."""
    var buf = List[UInt8]()
    var n = col
    while n > 0:
        var rem = (n - 1) % 26
        buf.append(UInt8(65 + rem))
        n = (n - 1) // 26
    var out = List[UInt8]()
    for k in range(len(buf)):
        out.append(buf[len(buf) - 1 - k])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _needs_quoting(name: String) -> Bool:
    """Does a sheet name have to be wrapped in single quotes?

    Excel quotes any name that is not a bare identifier — a space, punctuation,
    or a leading digit all force it. Letters, digits, `_` and `.` after a
    non-digit first character do not."""
    var bs = name.as_bytes()
    if len(bs) == 0:
        return False
    for k in range(len(bs)):
        var b = bs[k]
        var ok = (
            (b >= UInt8(0x41) and b <= UInt8(0x5A))
            or (b >= UInt8(0x61) and b <= UInt8(0x7A))
            or (b >= UInt8(0x30) and b <= UInt8(0x39))
            or b == UInt8(0x5F)
            or b == UInt8(0x2E)
        )
        if not ok:
            return True
    if bs[0] >= UInt8(0x30) and bs[0] <= UInt8(0x39):
        return True
    return False


def _sheet_prefix(name: String) -> String:
    """`Sheet1!`, or `'my sheet'!` when the name needs quoting. An embedded
    single quote is DOUBLED, which is what makes the result re-parseable."""
    if len(name.as_bytes()) == 0:
        return String("")
    if not _needs_quoting(name):
        return name + String("!")
    var out = String("'")
    for cp in name.codepoints():
        var ch = String(cp)
        out += ch
        if ch == String("'"):
            out += String("'")
    out += String("'!")
    return out^


def xl_address(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ADDRESS(row_num, column_num, [abs_num], [a1], [sheet_text])` — a cell
    reference as TEXT.

    ⭐ IT IS THE ONE MEMBER OF `Lookup and reference` THAT IS PURELY SCALAR:
    numbers in, text out, no reference value anywhere. That is why it is served
    here while `ROW`, `COLUMN`, `AREAS` and the dynamic-array members are
    refused by name — see this file's header.

    ⛔ `abs_num` IS A FOUR-WAY TABLE AND TWO OF ITS ROWS ARE EASY TO SWAP:

        1 (default)  `$C$2`   absolute row, absolute column
        2            `C$2`    ABSOLUTE ROW, relative column
        3            `$C2`    relative row, ABSOLUTE column
        4            `C2`     relative both

    2 and 3 are named after the ROW's state, so `2` puts the `$` on the ROW —
    the reading that looks backwards when written `C$2`, and the one a kernel
    gets wrong while passing the 1 and 4 cells.

    ⚠ `a1 = FALSE` SELECTS R1C1, where the brackets mean RELATIVE:
    `ADDRESS(2,3,1,FALSE)` is `R2C3` and `ADDRESS(2,3,4,FALSE)` is `R[2]C[3]`.
    A kernel that ignored `a1` answers `$C$2` for both.

    ⚠ REFUSALS: `row_num < 1`, `column_num < 1`, either past the worksheet
    ceiling, or an `abs_num` outside 1..4, is `#VALUE!`. Excel does not clamp,
    and a clamp here would format an address the sheet does not have."""
    var r = _num(args, 0)
    if r.is_error():
        return r^
    var c = _num(args, 1)
    if c.is_error():
        return c^
    var row = Int(r.num)
    var col = Int(c.num)
    if row < 1 or col < 1 or row > _XL_MAX_ROW or col > _XL_MAX_COL:
        return FormulaValue.error(XL_ERR_VALUE)

    var abs_num = 1
    if len(args) > 2:
        var a = _num(args, 2)
        if a.is_error():
            return a^
        abs_num = Int(a.num)
        if abs_num < 1 or abs_num > 4:
            return FormulaValue.error(XL_ERR_VALUE)

    var a1 = True
    if len(args) > 3:
        if args[3].is_error():
            return args[3].copy()
        var lv = args[3].coerce_logical()
        if lv.is_error():
            return lv^
        a1 = lv.logical

    var sheet = String("")
    if len(args) > 4:
        var s = args[4].coerce_text()
        if s.is_error():
            return s^
        sheet = _sheet_prefix(s.text)

    # abs_num: 1 = $row $col, 2 = $row rel-col, 3 = rel-row $col, 4 = both rel.
    var row_abs = abs_num == 1 or abs_num == 2
    var col_abs = abs_num == 1 or abs_num == 3

    if not a1:
        var out = sheet + String("R")
        if row_abs:
            out += String(row)
        else:
            out += String("[") + String(row) + String("]")
        out += String("C")
        if col_abs:
            out += String(col)
        else:
            out += String("[") + String(col) + String("]")
        return FormulaValue.text_val(out^)

    var out2 = sheet.copy()
    if col_abs:
        out2 += String("$")
    out2 += _col_letters(col)
    if row_abs:
        out2 += String("$")
    out2 += String(row)
    return FormulaValue.text_val(out2^)


def xl_hyperlink(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`HYPERLINK(link_location, [friendly_name])` — the DISPLAYED value.

    ⚠ WITH `friendly_name` OMITTED the value IS the link, which is the only
    case where the two readings coincide — so an omitted-argument cell cannot
    discriminate a kernel that returns the wrong argument.

    ⚠ A BLANK `friendly_name` is Excel's "show the link" case too: an omitted
    or empty second argument displays `link_location`."""
    var link = args[0].coerce_text()
    if link.is_error():
        return link^
    if len(args) < 2:
        return link^
    if args[1].is_error():
        return args[1].copy()
    if args[1].is_blank():
        return link^
    var friendly = args[1].coerce_text()
    if friendly.is_error():
        return friendly^
    if len(friendly.text.as_bytes()) == 0:
        return link^
    return friendly^
