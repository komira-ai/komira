# =============================================================================
# cast_string_to_number — STRING -> BIGINT / INTEGER / DOUBLE / REAL
# =============================================================================
#
# The text of a cell read as a number exactly as DuckDB v1.5.6 reads it in
# `CAST(<text> AS <type>)`, and NULL where DuckDB's `TRY_CAST` is NULL.
# docs/design/query_semantics.md §6.6 and §6.7 hold the rules; the SQL
# conformance cases `cast_text/*` hold the answers, run again by the pinned
# DuckDB.
#
# INTEGER TARGETS (BIGINT, INTEGER). The grammar and the arithmetic are
# DuckDB's `TrySimpleIntegerCast` (`integer_cast_operator.hpp`), step for
# step, because its answers are not those of exact arithmetic everywhere:
#
#   * leading whitespace is skipped; trailing whitespace may follow the digits,
#     the fraction or the exponent (not a hexadecimal or binary number);
#   * an optional `+` or `-`; decimal digits, leading zeros allowed; one `_`
#     between two digits (`1_000`);
#   * `0x` / `0b` (either case) after the whitespace and with no sign: a
#     hexadecimal or binary number, `_` between digits, at most the target's
#     maximum (no two's-complement wrap: `0xFFFFFFFFFFFFFFFF` is not -1);
#   * a fraction, `.` with digits on at least one side (`1.`, `.5`), which
#     rounds the result half away from zero on its FIRST digit
#     (`'2.5'` -> 3, `'-2.5'` -> -3, `'1.49999'` -> 1);
#   * an exponent, `e` / `E`, an optional sign and digits (an INT16), applied
#     the way DuckDB applies it: the digits are shifted between the integer
#     and its fraction and the same first-digit rounding follows. Where that
#     differs from exact arithmetic the answer is DuckDB's: `'5e-2'` is 1 (the
#     last digit shifted out decides), `'0.5e-1'` is 1, `'0.55e-1'` is 0, and
#     a fraction of 19 digits under an exponent wraps the 10^19 divisor
#     (`'1.9000000000000000000e0'` is 0). Each is measured.
#
#   The value is built in an INT64 for both targets; INTEGER range-checks the
#   rounded value (`'30000000000e-2'` is 300000000 as an INTEGER).
#
# FLOAT TARGETS (DOUBLE, REAL). DuckDB's `TryDoubleCast` over its fast_float:
#
#   * leading and trailing whitespace; one `+`, after which fast_float takes a
#     `-` (`'+-5'` is -5.0);
#   * digits with an optional `.` (at least one digit on either side), `_`
#     between two digits, an optional exponent;
#   * `nan` (optionally `nan(<letters, digits, _>)`), `inf`, `infinity`, any
#     case, with an optional `-` (`'-nan'` keeps its sign);
#   * the value is the CORRECTLY ROUNDED float (round to nearest, ties to
#     even), straight to the target width — REAL is not a DOUBLE rounded
#     again — by proto_codec's `parse_decimal_f64` / `parse_decimal_f32`;
#   * a value past the target's range is +-inf, and one below its smallest
#     subnormal a zero of its sign, as in DuckDB (`'1e400'` is inf).
#
# A CELL THAT IS NOT A NUMBER raises DuckDB's `Conversion Error: Could not
# convert string '<text>' to <TYPE>` under CAST and is NULL under TRY_CAST. A
# NULL cell is NULL under both.
# =============================================================================

from std.memory import bitcast

from arrow.primitive_array import PrimitiveArray
from arrow.string_array import StringArray
from proto_codec import parse_decimal_f32, parse_decimal_f64


comptime _SPACE = UInt8(32)
comptime _PLUS = UInt8(43)
comptime _MINUS = UInt8(45)
comptime _DOT = UInt8(46)
comptime _ZERO = UInt8(48)
comptime _UNDERSCORE = UInt8(95)
comptime _LPAREN = UInt8(40)
comptime _RPAREN = UInt8(41)

# An INT16 exponent's range, DuckDB's `IntegerCastData<int16_t>`.
comptime _EXP_MIN = -32768
comptime _EXP_MAX = 32767

# `NumericLimits<int64_t>::Digits()`: the widest divisor DuckDB builds when an
# exponent shifts fraction digits, 10^19, which wraps an INT64.
comptime _I64_DIGITS = 19


def _is_space(c: UInt8) -> Bool:
    """DuckDB's `CharacterIsSpace`: space, \\t, \\n, \\v, \\f, \\r."""
    return c == _SPACE or (c >= UInt8(9) and c <= UInt8(13))


def _is_digit(c: UInt8) -> Bool:
    return c >= _ZERO and c <= UInt8(57)


def _lower(c: UInt8) -> UInt8:
    if c >= UInt8(65) and c <= UInt8(90):
        return c + UInt8(32)
    return c


def _hex_value(c: UInt8) -> Int:
    """The value of a hexadecimal digit, or -1."""
    if _is_digit(c):
        return Int(c - _ZERO)
    var l = _lower(c)
    if l >= UInt8(97) and l <= UInt8(102):
        return Int(l - UInt8(97)) + 10
    return -1


# --- C's truncating INT64 division -----------------------------------------
#
# DuckDB divides with C++ `/` and `%`, which truncate toward zero; Mojo's `//`
# and `%` floor. The two differ for a negative operand, which both the
# negative-number path and the wrapped 10^19 divisor produce. Unsigned
# magnitudes make the truncation explicit.


def _magnitude(v: Int64) -> UInt64:
    if v >= 0:
        return v.cast[DType.uint64]()
    return UInt64(0) - v.cast[DType.uint64]()


def _tdiv(a: Int64, b: Int64) -> Int64:
    """`a / b` in C: the quotient truncated toward zero (`b` is never 0)."""
    var q = (_magnitude(a) // _magnitude(b)).cast[DType.int64]()
    if (a < 0) != (b < 0):
        return -q
    return q


def _trem(a: Int64, b: Int64) -> Int64:
    """`a % b` in C: the remainder takes the sign of `a`."""
    return a - _tdiv(a, b) * b


# --- Overflow-checked INT64 steps (DuckDB's `Try*Operator`) ------------------


def _times_ten(mut v: Int64) -> Bool:
    if v > Int64.MAX // 10 or v < _tdiv(Int64.MIN, 10):
        return False
    v = v * 10
    return True


# `_add` grows a non-negative number's integer and `_sub` a negative one's,
# by its fraction digits or by the rounding step: `a` is >= 0 in `_add` and
# <= 0 in `_sub`, and `b` is >= 0 but for the -1 a wrapped 10^19 divisor
# gives, so only a positive `b` can overflow.


def _add(mut a: Int64, b: Int64) -> Bool:
    if b > 0 and a > Int64.MAX - b:
        return False
    a = a + b
    return True


def _sub(mut a: Int64, b: Int64) -> Bool:
    if b > 0 and a < Int64.MIN + b:
        return False
    a = a - b
    return True


struct _IntCast(Copyable, Movable):
    """DuckDB's `IntegerDecimalCastData<T>`: the integer so far, the fraction
    digits read (`decimal`, up to what an INT64 holds) and how many."""

    var result: Int64
    var decimal: Int64
    var decimal_digits: Int

    def __init__(out self):
        self.result = Int64(0)
        self.decimal = Int64(0)
        self.decimal_digits = 0


def _push_digit(mut acc: Int64, d: Int64, negative: Bool) -> Bool:
    """`acc * 10 + d` (`- d` for a negative number), False past INT64."""
    if negative:
        if acc < _tdiv(Int64.MIN + d, 10):
            return False
        acc = acc * 10 - d
        return True
    if acc > (Int64.MAX - d) // 10:
        return False
    acc = acc * 10 + d
    return True


def _push_decimal(mut st: _IntCast, d: Int64):
    """`HandleDecimal`: digits past what an INT64 holds are dropped."""
    if st.decimal > (Int64.MAX - d) // 10:
        return
    st.decimal = st.decimal * 10 + d
    st.decimal_digits += 1


def _finalize(mut st: _IntCast, negative: Bool) -> Bool:
    """`Finalize`: round on the first fraction digit, half away from zero."""
    while st.decimal > 10:
        st.decimal = st.decimal // 10
        st.decimal_digits -= 1
    if st.decimal_digits == 1 and st.decimal >= 5:
        if negative:
            return _sub(st.result, Int64(1))
        return _add(st.result, Int64(1))
    return True


def _apply_exponent(mut st: _IntCast, exponent: Int, negative: Bool) -> Bool:
    """`HandleExponent`: shift digits between the integer and the fraction."""
    if exponent < 0:
        # Each step moves the integer's last digit into `decimal`, which keeps
        # only that one digit; the loop stops early once the integer is 0.
        var e = exponent
        while st.result != 0 and e < 0:
            e += 1
            st.decimal = _trem(st.result, 10)
            st.result = _tdiv(st.result, 10)
        if st.decimal < 0:
            st.decimal = -st.decimal
        st.decimal_digits = 1
        return _finalize(st, negative)
    var up = exponent
    while st.result != 0 and up > 0:
        up -= 1
        if not _times_ten(st.result):
            return False
    if st.decimal == 0:
        return _finalize(st, negative)
    # Move `exponent` fraction digits into the integer.
    var e = exponent - st.decimal_digits
    var remainder = Int64(0)
    if e < 0:
        if -e <= _I64_DIGITS:
            # 10^19 wraps an INT64 here, as it does in DuckDB.
            var power = UInt64(1)
            for _ in range(-e):
                power = power * UInt64(10)
            var p = power.cast[DType.int64]()
            remainder = _trem(st.decimal, p)
            st.decimal = _tdiv(st.decimal, p)
        else:
            st.decimal = Int64(0)
    else:
        for _ in range(e):
            if not _times_ten(st.decimal):
                return False
    st.decimal_digits -= exponent
    var ok: Bool
    if negative:
        ok = _sub(st.result, st.decimal)
    else:
        ok = _add(st.result, st.decimal)
    if not ok:
        return False
    st.decimal = remainder
    return _finalize(st, negative)


def _skip_trailing_space(b: Span[UInt8, _], var p: Int, hi: Int) -> Bool:
    """True when every byte of `b[p:hi]` is whitespace."""
    while p < hi:
        if not _is_space(b[p]):
            return False
        p += 1
    return True


def _parse_exponent(b: Span[UInt8, _], lo: Int, hi: Int) -> Optional[Int]:
    """The exponent after `e`: DuckDB's simple INT16 cast of `b[lo:hi]`. A
    `.` is accepted only with no digit after it (`'1e2.'` is 100)."""
    var negative = b[lo] == _MINUS
    var start = lo + 1 if (negative or b[lo] == _PLUS) else lo
    var p = start
    var acc = 0
    while p < hi:
        var c = b[p]
        if not _is_digit(c):
            if c == _DOT:
                var before = p > start
                p += 1
                if p < hi and _is_digit(b[p]):
                    return None
                if not before:
                    return None
                if p >= hi:
                    break
            if _is_space(b[p]):
                if not _skip_trailing_space(b, p + 1, hi):
                    return None
                p = hi
                break
            return None
        var d = Int(c - _ZERO)
        if negative:
            if acc * 10 - d < _EXP_MIN:
                return None
            acc = acc * 10 - d
        else:
            if acc * 10 + d > _EXP_MAX:
                return None
            acc = acc * 10 + d
        p += 1
        if p < hi and b[p] == _UNDERSCORE:
            p += 1
            if p >= hi or not _is_digit(b[p]):
                return None
    if p <= start:
        return None
    return acc


def _parse_decimal_int(b: Span[UInt8, _], lo: Int, hi: Int, negative: Bool) -> Optional[Int64]:
    """DuckDB's `IntegerCastLoop` with `IntegerDecimalCastOperation` over
    `b[lo:hi]`, which starts at the sign if there is one."""
    var start = lo + 1 if (negative or b[lo] == _PLUS) else lo
    var p = start
    var st = _IntCast()
    while p < hi:
        var c = b[p]
        if not _is_digit(c):
            if c == _DOT:
                var before = p > start
                p += 1
                var first = p
                while p < hi and _is_digit(b[p]):
                    _push_decimal(st, Int64(Int(b[p] - _ZERO)))
                    p += 1
                    if p < hi and b[p] == _UNDERSCORE:
                        p += 1
                        if p >= hi or not _is_digit(b[p]):
                            return None
                if not (before or p > first):
                    return None
                if p >= hi:
                    break
            if _is_space(b[p]):
                if not _skip_trailing_space(b, p + 1, hi):
                    return None
                p = hi
                break
            if b[p] == UInt8(101) or b[p] == UInt8(69):  # 'e' / 'E'
                if p == start:
                    return None
                p += 1
                if p >= hi:
                    return None
                var exponent = _parse_exponent(b, p, hi)
                if not exponent:
                    return None
                if not _apply_exponent(st, exponent.value(), negative):
                    return None
                return st.result
            return None
        if not _push_digit(st.result, Int64(Int(c - _ZERO)), negative):
            return None
        p += 1
        if p < hi and b[p] == _UNDERSCORE:
            p += 1
            if p >= hi or not _is_digit(b[p]):
                return None
    if not _finalize(st, negative):
        return None
    if p <= start:
        return None
    return st.result


def _parse_radix_int(b: Span[UInt8, _], lo: Int, hi: Int, radix: Int) -> Optional[Int64]:
    """DuckDB's `IntegerHexCastLoop` / `IntegerBinaryCastLoop` over the digits
    `b[lo:hi]` (after `0x` / `0b`): no sign, no trailing whitespace, `_`
    between digits, at most INT64's maximum."""
    var p = lo
    var acc = Int64(0)
    while p < hi:
        var d = _hex_value(b[p])
        if d < 0 or d >= radix:
            return None
        p += 1
        if p < hi and b[p] == _UNDERSCORE:
            p += 1
            if p >= hi:
                return None
            var next = _hex_value(b[p])
            if next < 0 or next >= radix:
                return None
        if acc > (Int64.MAX - Int64(d)) // Int64(radix):
            return None
        acc = acc * Int64(radix) + Int64(d)
    if p <= lo:
        return None
    return acc


def parse_text_int64(text: String) -> Optional[Int64]:
    """The BIGINT DuckDB reads from `text` in `CAST(text AS BIGINT)`, or None
    where that cast fails (the module header lists the grammar)."""
    var b = text.as_bytes()
    var n = len(b)
    var lo = 0
    while lo < n and _is_space(b[lo]):
        lo += 1
    if lo == n:
        return None
    if b[lo] == _MINUS:
        return _parse_decimal_int(b, lo, n, True)
    if n - lo > 1 and b[lo] == _ZERO:
        var x = _lower(b[lo + 1])
        if x == UInt8(120):  # 'x'
            return _parse_radix_int(b, lo + 2, n, 16)
        if x == UInt8(98):  # 'b'
            return _parse_radix_int(b, lo + 2, n, 2)
    return _parse_decimal_int(b, lo, n, False)


def parse_text_int32(text: String) -> Optional[Int32]:
    """The INTEGER DuckDB reads from `text`, or None: the INT64 value of
    `parse_text_int64`, range-checked after rounding."""
    var v = parse_text_int64(text)
    if not v:
        return None
    var x = v.value()
    if x > Int64(Int32.MAX) or x < Int64(Int32.MIN):
        return None
    return Int32(x)


def _starts_with_lower(b: Span[UInt8, _], p: Int, n: Int, word: StaticString) -> Bool:
    var w = word.as_bytes()
    if n - p < len(w):
        return False
    for k in range(len(w)):
        if _lower(b[p + k]) != w[k]:
            return False
    return True


def _is_nan_seq_char(c: UInt8) -> Bool:
    return _is_digit(c) or c == _UNDERSCORE or (_lower(c) >= UInt8(97) and _lower(c) <= UInt8(122))


def _scan_digits(b: Span[UInt8, _], var p: Int, n: Int, mut out: String) -> Tuple[Int, Bool]:
    """Append the digits at `b[p:]` to `out`, skipping one `_` between two
    digits. Returns the end and False when an `_` is not between digits."""
    while p < n and _is_digit(b[p]):
        out += chr(Int(b[p]))
        p += 1
        if p < n and b[p] == _UNDERSCORE:
            if p + 1 >= n or not _is_digit(b[p + 1]):
                return (p, False)
            p += 1
    return (p, True)


@fieldwise_init
struct _FloatText(Copyable, Movable):
    """A DOUBLE / REAL cell as `TryDoubleCast` reads it: a special value, or
    the number as text `parse_decimal_f64` takes (no `_`, digits on both
    sides of any `.`)."""

    var negative: Bool
    var special: UInt8  # 0: a number in `text`; 1: NaN; 2: infinity
    var text: String


def _float_text(text: String) -> Optional[_FloatText]:
    var b = text.as_bytes()
    var n = len(b)
    var p = 0
    while p < n and _is_space(b[p]):
        p += 1
    if p == n:
        return None
    if b[p] == _PLUS:
        p += 1
    var negative = False
    if p < n and b[p] == _MINUS:
        negative = True
        p += 1
    var num = String("-") if negative else String("")
    var int_digits = String("")
    var r = _scan_digits(b, p, n, int_digits)
    if not r[1]:
        return None
    p = r[0]
    var frac_digits = String("")
    var saw_dot = False
    if p < n and b[p] == _DOT:
        saw_dot = True
        # A `_` right after the `.` is not between digits.
        if p + 1 < n and b[p + 1] == _UNDERSCORE:
            return None
        var f = _scan_digits(b, p + 1, n, frac_digits)
        if not f[1]:
            return None
        p = f[0]
    if int_digits.byte_length() == 0 and frac_digits.byte_length() == 0:
        # No digits: `nan`, `inf` or `infinity`, or not a number. A lone `.`
        # (with or without a sign) lands here too and is not one.
        if saw_dot:
            return None
        var special = UInt8(0)
        if _starts_with_lower(b, p, n, "nan"):
            special = 1
            p += 3
            if p < n and b[p] == _LPAREN:
                var q = p + 1
                while q < n and _is_nan_seq_char(b[q]):
                    q += 1
                if q < n and b[q] == _RPAREN:
                    p = q + 1
        elif _starts_with_lower(b, p, n, "inf"):
            special = 2
            p += 3
            if _starts_with_lower(b, p, n, "inity"):
                p += 5
        else:
            return None
        if not _skip_trailing_space(b, p, n):
            return None
        return _FloatText(negative, special, String(""))
    num += int_digits if int_digits.byte_length() > 0 else String("0")
    if frac_digits.byte_length() > 0:
        num += "." + frac_digits
    if p < n and (b[p] == UInt8(101) or b[p] == UInt8(69)):  # 'e' / 'E'
        var q = p + 1
        var sign = String("")
        if q < n and (b[q] == _PLUS or b[q] == _MINUS):
            sign = chr(Int(b[q]))
            q += 1
        if q >= n or not _is_digit(b[q]):
            return None
        var exp_digits = String("")
        var e = _scan_digits(b, q, n, exp_digits)
        if not e[1]:
            return None
        num += "e" + sign + exp_digits
        p = e[0]
    if not _skip_trailing_space(b, p, n):
        return None
    return _FloatText(negative, UInt8(0), num^)


# Fixed bit patterns: a NaN computed as 0.0 / 0.0 takes its sign from the
# hardware's default NaN when the division runs (set on x86) and not when it
# folds, and `-nan` must keep exactly the sign the text gives.


def _nan64() -> Float64:
    return bitcast[DType.float64](UInt64(0x7FF8000000000000))


def _inf64() -> Float64:
    return bitcast[DType.float64](UInt64(0x7FF0000000000000))


def _f64_of(t: _FloatText) raises -> Float64:
    """The DOUBLE `t` names. Raises only if the exact parser refuses the text
    `_float_text` built, which is a defect here, not a property of the cell."""
    if t.special == 1:
        return -_nan64() if t.negative else _nan64()
    if t.special == 2:
        return -_inf64() if t.negative else _inf64()
    try:
        return parse_decimal_f64(t.text)
    except e:
        if String(e).find("out of double range") < 0:
            raise Error("parse_text_float64: " + String(e))
        return -_inf64() if t.negative else _inf64()


def _f32_of(t: _FloatText) raises -> Float32:
    """The REAL `t` names, rounded once, straight to float32. Raises as
    `_f64_of` does."""
    if t.special == 1:
        var nan = Float32(_nan64())
        return -nan if t.negative else nan
    if t.special == 2:
        var inf = Float32(_inf64())
        return -inf if t.negative else inf
    try:
        return parse_decimal_f32(t.text)
    except e:
        if String(e).find("out of float32 range") < 0:
            raise Error("parse_text_float32: " + String(e))
        var inf = Float32(_inf64())
        return -inf if t.negative else inf


def parse_text_float64(text: String) raises -> Optional[Float64]:
    """The DOUBLE DuckDB reads from `text`, or None where that cast fails."""
    var ft = _float_text(text)
    if not ft:
        return None
    return _f64_of(ft.value())


def parse_text_float32(text: String) raises -> Optional[Float32]:
    """The REAL DuckDB reads from `text`, or None where that cast fails."""
    var ft = _float_text(text)
    if not ft:
        return None
    return _f32_of(ft.value())


def _conversion_error(text: String, type_name: StaticString) -> Error:
    return Error(
        "Conversion Error: Could not convert string '" + text + "' to "
        + String(type_name)
    )


# =============================================================================
# Scalar parsers: the value, or DuckDB's Conversion Error
# =============================================================================


def i64_from_str(s: String) raises -> Int64:
    """`CAST(s AS BIGINT)`: raises DuckDB's Conversion Error where it fails."""
    var v = parse_text_int64(s)
    if not v:
        raise _conversion_error(s, "INT64")
    return v.value()


def i32_from_str(s: String) raises -> Int32:
    """`CAST(s AS INTEGER)`: raises DuckDB's Conversion Error where it fails."""
    var v = parse_text_int32(s)
    if not v:
        raise _conversion_error(s, "INT32")
    return v.value()


def f64_from_str(s: String) raises -> Float64:
    """`CAST(s AS DOUBLE)`: raises DuckDB's Conversion Error where it fails."""
    var v = parse_text_float64(s)
    if not v:
        raise _conversion_error(s, "DOUBLE")
    return v.value()


def f32_from_str(s: String) raises -> Float32:
    """`CAST(s AS REAL)`: raises DuckDB's Conversion Error where it fails."""
    var v = parse_text_float32(s)
    if not v:
        raise _conversion_error(s, "FLOAT")
    return v.value()


# =============================================================================
# Column kernels: a NULL cell is NULL; a cell that is not a number raises
# (CAST) or is NULL (`try_mode`, TRY_CAST)
# =============================================================================


def cast_string_to_int64(sa: StringArray, try_mode: Bool = False) raises -> PrimitiveArray[DType.int64]:
    """STRING -> BIGINT over a column, by `parse_text_int64`."""
    var n = sa.length
    var out = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var s = sa.get(i)
        var v = parse_text_int64(s)
        if v:
            out.set(i, Scalar[DType.int64](v.value()))
        elif try_mode:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise _conversion_error(s, "INT64")
    out.null_count = nc
    return out^


def cast_string_to_int32(sa: StringArray, try_mode: Bool = False) raises -> PrimitiveArray[DType.int32]:
    """STRING -> INTEGER over a column, by `parse_text_int32`."""
    var n = sa.length
    var out = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var s = sa.get(i)
        var v = parse_text_int32(s)
        if v:
            out.set(i, Scalar[DType.int32](v.value()))
        elif try_mode:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise _conversion_error(s, "INT32")
    out.null_count = nc
    return out^


def cast_string_to_float64(sa: StringArray, try_mode: Bool = False) raises -> PrimitiveArray[DType.float64]:
    """STRING -> DOUBLE over a column, by `parse_text_float64`."""
    var n = sa.length
    var out = PrimitiveArray[DType.float64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var s = sa.get(i)
        var v = parse_text_float64(s)
        if v:
            out.set(i, Scalar[DType.float64](v.value()))
        elif try_mode:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise _conversion_error(s, "DOUBLE")
    out.null_count = nc
    return out^


def cast_string_to_float32(sa: StringArray, try_mode: Bool = False) raises -> PrimitiveArray[DType.float32]:
    """STRING -> REAL over a column, by `parse_text_float32`."""
    var n = sa.length
    var out = PrimitiveArray[DType.float32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if sa.is_null(i):
            out.validity.value().clear(i)
            nc += 1
            continue
        var s = sa.get(i)
        var v = parse_text_float32(s)
        if v:
            out.set(i, Scalar[DType.float32](v.value()))
        elif try_mode:
            out.validity.value().clear(i)
            nc += 1
        else:
            raise _conversion_error(s, "FLOAT")
    out.null_count = nc
    return out^
