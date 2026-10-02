# =============================================================================
# xl_scalar_exact.mojo — ★ THE EXACT-ANSWER MATH KERNELS: COMBINATORICS,
#                          RADIX CONVERSION, AND THE `.PRECISE` ROUNDING PAIR.
# =============================================================================
#
# ============ ⚠⚠ WHAT MAKES THESE ONE FILE, AND IT IS NOT "MORE MATH" =======
#
# ⭐ EVERY FUNCTION HERE HAS A SINGLE EXACTLY-REPRESENTABLE ANSWER AND NEEDS NO
# TOLERANCE. That is the property that separates them from
# `xl_scalar_numeric.mojo`, whose transcendental block is DECLARED-EXCLUDED
# from the scalar VALUE sweep precisely because its expectations need a
# floating-point tolerance argued per function. A cell here can be graded as an
# exact integer or an exact string, so every one of them earns a value cell.
#
# ============ ⛔⛔ AND EVERY NAME HERE HAS A NEIGHBOUR IT CAN BE MIS-WIRED TO
#
# This is the named vacuity of the whole Excel coverage effort: *a registry
# row wired to the WRONG KERNEL still answers, so it is not `#NAME?`, so a
# recognition cell passes.* `TRUNC` wired to `INT` passes such a cell. Six of
# the nine functions below have a plausible wrong twin ALREADY IN THIS TREE:
#
#   FACTDOUBLE     -> FACT              agree at 0,1,2,3; differ at 6 (48/720)
#   COMBINA        -> COMBIN            agree at k<=1; differ at (5,2) (15/10)
#   CEILING.PRECISE-> CEILING           agree when both args are positive;
#                                       differ at a NEGATIVE significance, where
#                                       CEILING is #NUM! or rounds the other way
#   FLOOR.PRECISE  -> FLOOR             the mirror of the same
#   DECIMAL        -> a permissive int  parse: a radix-blind parser reads
#                                       DECIMAL("2",2) as 2 where Excel refuses
#   BASE           -> a lower-case      renderer: "ff" for BASE(255,16)
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins, no `unsafe_from_address`.
# =============================================================================

from std.math import floor, ceil

from komira_core.plan.excel_error_code import XL_ERR_NUM, XL_ERR_VALUE

from .formula_value import FormulaValue


# `2**53` — the largest integer every smaller integer of which a Float64 holds
# exactly. Past it an "integer" answer is already a rounded one, so the kernels
# here refuse rather than return a number that looks exact and is not.
comptime _INT_EXACT_MAX: Float64 = 9007199254740992.0


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` as a NUMBER, or the error that stops the call. Same
    contract as `xl_scalar_math._num` / `xl_scalar_numeric._num`, re-spelled
    for the same reason those two are: a cross-module import of a private
    helper is the edge that makes a "kernels only" module stop being one.
    ⚠ IF THE DOMINANCE RULE EVER CHANGES, ALL THREE CHANGE."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


def _trunc_toward_zero(x: Float64) -> Float64:
    """The integer part, TOWARD ZERO. ⚠ NOT `floor` — Excel truncates each
    argument of FACT / COMBIN / BASE, so `FACT(5.9)` is `FACT(5)` = 120 and a
    ROUNDING kernel answers 720."""
    return floor(x) if x >= 0.0 else ceil(x)


def _nonneg_int(imm v: FormulaValue) -> Optional[Int]:
    """A NUMBER argument TRUNCATED to a non-negative exactly-representable
    integer, or `None` when the caller must refuse. Mirrors
    `xl_scalar_numeric._int_arg`."""
    var t = _trunc_toward_zero(v.num)
    if t < 0.0 or t > _INT_EXACT_MAX:
        return Optional[Int]()
    return Optional[Int](Int(t))


# =============================================================================
# ★ FACTORIALS — and the pair is the point.
# =============================================================================
def xl_fact(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FACT(number)` — `number!`, the ordinary factorial.

    ⚠ THE ARGUMENT IS TRUNCATED, NOT ROUNDED. `FACT(5.9)` is `FACT(5)` = 120;
    a kernel that rounded would answer 720, a perfectly plausible number.

    ⚠ `FACT(0)` IS 1 (the empty product), and a NEGATIVE argument is `#NUM!` —
    Excel refuses rather than taking an absolute value.

    ⚠ THE CEILING IS 170. `171!` overflows Float64 to `+inf`, which would
    travel silently through every comparison and aggregate above it; `#NUM!`
    STOPS. That is the same argument `xl_ln` makes about `log(0)`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var n_opt = _nonneg_int(x)
    if not n_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var n = n_opt.value()
    if n > 170:
        return FormulaValue.error(XL_ERR_NUM)
    var acc: Float64 = 1.0
    for i in range(2, n + 1):
        acc = acc * Float64(i)
    return FormulaValue.number(acc)


def xl_factdouble(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FACTDOUBLE(number)` — the DOUBLE factorial `n!!`, i.e. the product of
    `n, n-2, n-4, ...` down to 2 or 1.

    ⛔⛔ THIS IS THE FILE'S FLAGSHIP MIS-WIRING RISK AND IT IS NOT HYPOTHETICAL.
    `FACTDOUBLE` wired to `FACT` answers CORRECTLY at 0, 1, 2 and 3 — the four
    inputs a lazy fixture uses — and diverges from 4 upward. `FACTDOUBLE(6)` is
    `6*4*2` = **48** where `FACT(6)` is 720, and `FACTDOUBLE(7)` is `7*5*3*1` =
    **105** where `FACT(7)` is 5040. The oracle carries 6 AND the blind 2.

    ⚠ A NEGATIVE ARGUMENT IS `#NUM!`. Excel's `FACTDOUBLE(-1)` is documented as
    `#NUM!`, which is NOT the mathematical convention (`(-1)!! = 1`); this
    follows Excel, which is the surface being emulated.

    ⚠ THE CEILING IS 300. `301!!` overflows Float64; the limit is HIGHER than
    `FACT`'s 170 because half as many factors multiply, and stating a
    `FACT`-shaped 170 here would refuse inputs Excel answers."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var n_opt = _nonneg_int(x)
    if not n_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var n = n_opt.value()
    if n > 300:
        return FormulaValue.error(XL_ERR_NUM)
    var acc: Float64 = 1.0
    var k = n
    while k > 1:
        acc = acc * Float64(k)
        k -= 2
    return FormulaValue.number(acc)


# =============================================================================
# ★ COMBINATIONS — with and WITHOUT repetition, and they are different numbers.
# =============================================================================
def _comb(n: Int, k: Int) -> Float64:
    """`C(n, k)` by the multiplicative recurrence, which divides at every step
    so the intermediate never exceeds the answer. ⚠ THE DIVISION IS EXACT AT
    EVERY STEP — `acc * (n-k+i) / i` is an integer for every `i`, because the
    partial product is already `C(n-k+i, i)` — so the Float64 loop returns the
    exact integer for every answer below 2**53 and no rounding is needed."""
    var kk = k
    if kk > n - kk:
        kk = n - kk
    var acc: Float64 = 1.0
    for i in range(1, kk + 1):
        acc = acc * Float64(n - kk + i) / Float64(i)
    return acc


def xl_combin(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COMBIN(number, number_chosen)` — combinations WITHOUT repetition.

    ⚠ BOTH ARGUMENTS ARE TRUNCATED. `COMBIN(5.9, 2.9)` is `COMBIN(5, 2)` = 10.

    ⚠ `number_chosen > number` IS `#NUM!`, not 0. That distinction matters: a
    kernel returning 0 produces a number that sums happily into a total."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var b = _num(args, 1)
    if b.is_error():
        return b^
    var n_opt = _nonneg_int(a)
    var k_opt = _nonneg_int(b)
    if not n_opt or not k_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var n = n_opt.value()
    var k = k_opt.value()
    if k > n:
        return FormulaValue.error(XL_ERR_NUM)
    var v = _comb(n, k)
    if v > _INT_EXACT_MAX:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(v)


def xl_combina(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`COMBINA(number, number_chosen)` — combinations WITH repetition, i.e.
    `C(n + k - 1, k)`.

    ⛔ `COMBINA` WIRED TO `COMBIN` ANSWERS CORRECTLY FOR EVERY `k <= 1` and
    diverges from `k = 2` upward: `COMBINA(5, 2)` is **15** where
    `COMBIN(5, 2)` is 10. The oracle carries (5,2) AND the blind (5,1), where
    both are 5.

    ⚠ `number_chosen` MAY EXCEED `number` — that is the whole point of drawing
    with replacement, and it is the second way this differs from `COMBIN`,
    which refuses. `COMBINA(2, 5)` is 6; `COMBIN(2, 5)` is `#NUM!`.

    ⚠ `COMBINA(0, 0)` IS 1 and `COMBINA(0, k>0)` IS `#NUM!` — there is nothing
    to draw from. Both are Excel's answers."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var b = _num(args, 1)
    if b.is_error():
        return b^
    var n_opt = _nonneg_int(a)
    var k_opt = _nonneg_int(b)
    if not n_opt or not k_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var n = n_opt.value()
    var k = k_opt.value()
    if n == 0:
        if k == 0:
            return FormulaValue.number(1.0)
        return FormulaValue.error(XL_ERR_NUM)
    var v = _comb(n + k - 1, k)
    if v > _INT_EXACT_MAX:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(v)


# =============================================================================
# ★ SUMSQ
# =============================================================================
def xl_sumsq(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SUMSQ(number1, ...)` — the sum of the SQUARES of the arguments.

    ⚠ IT IS NOT `SUM`, AND THE NAMES ARE ONE LETTER APART. `SUMSQ(3, 4)` is
    **25** where `SUM(3, 4)` is 7. It is also not `SUM` of absolute values:
    `SUMSQ(-3)` is 9, not 3.

    ⚠ BLANKS ARE SKIPPED, not coerced to 0 — which happens to give the same
    number here (0 squared is 0) and is spelled explicitly anyway, because the
    reason it is safe is arithmetic accident rather than design, and the next
    kernel copied from this one may not have it."""
    var acc: Float64 = 0.0
    for i in range(len(args)):
        if args[i].is_blank():
            continue
        var v = _num(args, i)
        if v.is_error():
            return v^
        acc = acc + v.num * v.num
    return FormulaValue.number(acc)


# =============================================================================
# ★ RADIX CONVERSION — BASE and DECIMAL, the two directions of one map.
# =============================================================================
comptime _DIGITS: StaticString = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def xl_base(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`BASE(number, radix, [min_length])` — `number` rendered in `radix`.

    ⚠ THE DIGITS ABOVE 9 ARE UPPER-CASE. `BASE(255, 16)` is `"FF"`, not
    `"ff"` — a lower-case renderer is the plausible wrong implementation and
    the oracle grades the exact string.

    ⚠ `min_length` LEFT-PADS WITH ZEROS AND NEVER TRUNCATES: `BASE(7, 2, 8)` is
    `"00000111"`, and a `min_length` shorter than the rendering is ignored
    rather than being an error.

    ⚠ THE REFUSALS: a radix outside 2..36 is `#NUM!`, a negative `number` is
    `#NUM!`, a `number` past 2**53 is `#NUM!` (it is no longer an exact
    integer), and a `min_length` outside 0..255 is `#NUM!`. `BASE(0, 2)` is
    `"0"` — the one input where an accumulate-digits loop that never runs
    returns the empty string instead."""
    var a = _num(args, 0)
    if a.is_error():
        return a^
    var b = _num(args, 1)
    if b.is_error():
        return b^
    var n_opt = _nonneg_int(a)
    var r_opt = _nonneg_int(b)
    if not n_opt or not r_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var n = n_opt.value()
    var radix = r_opt.value()
    if radix < 2 or radix > 36:
        return FormulaValue.error(XL_ERR_NUM)
    var min_len = 0
    if len(args) >= 3:
        var c = _num(args, 2)
        if c.is_error():
            return c^
        var m_opt = _nonneg_int(c)
        if not m_opt:
            return FormulaValue.error(XL_ERR_NUM)
        min_len = m_opt.value()
        if min_len > 255:
            return FormulaValue.error(XL_ERR_NUM)
    var rev = List[UInt8]()
    var v = n
    if v == 0:
        rev.append(UInt8(ord("0")))
    while v > 0:
        rev.append(_DIGITS.as_bytes()[v % radix])
        v //= radix
    while len(rev) < min_len:
        rev.append(UInt8(ord("0")))
    var out = List[UInt8]()
    for i in range(len(rev)):
        out.append(rev[len(rev) - 1 - i])
    return FormulaValue.text_val(String(StringSlice(unsafe_from_utf8=Span(out))))


def xl_decimal(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`DECIMAL(text, radix)` — the inverse of `BASE`.

    ⛔⛔ A DIGIT THAT IS NOT VALID IN `radix` IS `#NUM!`, AND THIS IS THE ONE
    PROPERTY A PLAUSIBLE WRONG IMPLEMENTATION LOSES. A parser that accumulates
    `value*radix + digit` without checking the digit against the radix reads
    `DECIMAL("2", 2)` as **2**; Excel refuses it. The oracle carries that cell.

    ⚠ IT IS CASE-INSENSITIVE: `DECIMAL("ff", 16)` and `DECIMAL("FF", 16)` are
    both 255.

    ⚠ THE REFUSALS: a radix outside 2..36 is `#NUM!`; text longer than 255
    characters is `#VALUE!`; an EMPTY text is `#NUM!` here — Microsoft's page
    does not state the empty case, so this engine refuses rather than
    inventing the 0 that an accumulate-from-zero loop would silently return,
    and that refusal is a DIVERGENCE RISK rather than a documented rule. It is
    deliberately not graded as an Excel-agreeing cell."""
    if args[0].is_error():
        return args[0].copy()
    var t = args[0].coerce_text()
    if t.is_error():
        return t^
    var b = _num(args, 1)
    if b.is_error():
        return b^
    var r_opt = _nonneg_int(b)
    if not r_opt:
        return FormulaValue.error(XL_ERR_NUM)
    var radix = r_opt.value()
    if radix < 2 or radix > 36:
        return FormulaValue.error(XL_ERR_NUM)
    var up = t.text.upper()
    var bs = up.as_bytes()
    if len(bs) == 0:
        return FormulaValue.error(XL_ERR_NUM)
    if len(bs) > 255:
        return FormulaValue.error(XL_ERR_VALUE)
    var acc: Float64 = 0.0
    for i in range(len(bs)):
        var c = Int(bs[i])
        var d = -1
        if c >= ord("0") and c <= ord("9"):
            d = c - ord("0")
        elif c >= ord("A") and c <= ord("Z"):
            d = c - ord("A") + 10
        if d < 0 or d >= radix:
            return FormulaValue.error(XL_ERR_NUM)
        acc = acc * Float64(radix) + Float64(d)
        if acc > _INT_EXACT_MAX:
            return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(acc)


# =============================================================================
# ★★ THE `.PRECISE` ROUNDING PAIR — THE MIS-WIRING THIS CAMPAIGN IS NAMED FOR
# =============================================================================
#
# ⛔⛔ `CEILING.PRECISE` WIRED TO `CEILING` PASSES EVERY POSITIVE-ARGUMENT CELL.
# The two functions are DIFFERENT in exactly two ways and both involve a sign:
#
#   (1) `CEILING` selects its direction from whether `number` and
#       `significance` SHARE a sign (away from zero when they do, toward zero
#       when they do not) — the six-case table `_significance_guard` documents.
#       `CEILING.PRECISE` always rounds toward **+infinity**, whatever the
#       signs.
#   (2) `CEILING` REFUSES a positive `number` with a negative `significance`
#       (`#NUM!`). `CEILING.PRECISE` takes the ABSOLUTE VALUE of
#       `significance`, so it answers.
#
# ⇒ the separating inputs are `(-2.5, -1)` — `CEILING` is -3, `CEILING.PRECISE`
#   is -2 — and `(2.5, -1)`, where `CEILING` is `#NUM!` and `CEILING.PRECISE`
#   is 3. `(2.5, 1)` is the BLIND cell where both answer 3, and it is the first
#   input anybody writes.
# =============================================================================
def _precise_significance(imm args: List[FormulaValue]) -> FormulaValue:
    """The shared optional-`significance` reader for the `.PRECISE` pair:
    absent means 1, and the SIGN IS DISCARDED. Returns the magnitude as a
    NUMBER, or the error that stops the call."""
    if len(args) < 2:
        return FormulaValue.number(1.0)
    if args[1].is_error():
        return args[1].copy()
    var s = args[1].coerce_number()
    if s.is_error():
        return s^
    var m = s.num
    if m < 0.0:
        m = -m
    return FormulaValue.number(m)


def xl_ceiling_precise(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CEILING.PRECISE(number, [significance])` — up toward +infinity, always.

    ⚠ `significance` IS OPTIONAL (default 1), where `CEILING`'s is REQUIRED.
    That arity difference is itself a discriminator: `CEILING(4.3)` is refused
    by arity and `CEILING.PRECISE(4.3)` is 5.

    ⚠ A ZERO `significance` RETURNS 0, which is Excel's answer and matches
    `_significance_guard`'s first case."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var s = _precise_significance(args)
    if s.is_error():
        return s^
    if s.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(ceil(x.num / s.num) * s.num)


def xl_floor_precise(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FLOOR.PRECISE(number, [significance])` — down toward -infinity, always.

    The mirror of `CEILING.PRECISE`, and the mirror of the mis-wiring:
    `FLOOR.PRECISE(-2.5, -1)` is **-3** where `FLOOR(-2.5, -1)` is -2, and
    `FLOOR.PRECISE(2.5, -1)` is **2** where `FLOOR(2.5, -1)` is `#NUM!`.
    `(2.5, 1)` is the blind cell, 2 either way."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    var s = _precise_significance(args)
    if s.is_error():
        return s^
    if s.num == 0.0:
        return FormulaValue.number(0.0)
    return FormulaValue.number(floor(x.num / s.num) * s.num)

# =============================================================================
# ⭐⭐ THE 2026-09-14 MATH TRANCHE — MULTINOMIAL / ROMAN / ARABIC / ISO.CEILING
#
# ★ WHAT MAKES THESE FOUR BELONG IN *THIS* FILE AND NOT IN `xl_scalar_numeric`
# IS THE SAME PROPERTY THE NINE ABOVE SHARE: every one has a SINGLE
# exactly-representable answer and needs no tolerance, so every one earns a
# graded VALUE cell rather than a declared exclusion.
# =============================================================================
def xl_multinomial(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`MULTINOMIAL(n1, n2, ...)` — `(sum n)! / (n1! * n2! * ...)`.

    ⛔ IT IS NOT A PRODUCT OF FACTORIALS AND IT IS NOT A SUM OF THEM. The two
    plausible misreadings both answer a number: for `(2, 3)` the correct answer
    is `5!/(2!*3!)` = 10, a product of factorials is 12 and a sum is 8. None of
    the three is an error, so only a VALUE cell separates them.

    ⚠ EVERY ARGUMENT IS TRUNCATED, and a NEGATIVE one is `#NUM!` — the same
    refusal `FACT` makes rather than taking an absolute value.

    ⚠ COMPUTED AS A RUNNING BINOMIAL PRODUCT, NOT AS `fact(total)/prod(fact)`.
    The direct spelling overflows at a total of 171 while the answer is still
    small — `MULTINOMIAL(170, 170)` is ~1e102, comfortably finite, where `340!`
    is `+inf`. The running form multiplies and divides alternately and stays in
    range wherever the ANSWER is in range, which is the property that matters.
    ⚠ AND IT IS EXACT while the intermediate products are: each step is an
    integer binomial coefficient."""
    if len(args) == 0:
        return FormulaValue.error(XL_ERR_VALUE)
    var counts = List[Int]()
    for i in range(len(args)):
        var a = _num(args, i)
        if a.is_error():
            return a^
        var n_opt = _nonneg_int(a)
        if not n_opt:
            return FormulaValue.error(XL_ERR_NUM)
        counts.append(n_opt.value())
    # (n1+n2+...)! / (n1! n2! ...) == prod_k C(running_total_k, n_k).
    var acc: Float64 = 1.0
    var total = 0
    for i in range(len(counts)):
        var n = counts[i]
        total += n
        # C(total, n), built multiplicatively so each partial stays integral.
        for j in range(1, n + 1):
            acc = acc * Float64(total - n + j) / Float64(j)
        if acc > _MULTINOMIAL_MAX:
            return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.number(acc)


def xl_iso_ceiling(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ISO.CEILING(number, [significance])` — up toward +infinity, always.

    ⚠⚠ IT IS THE SAME FUNCTION AS `CEILING.PRECISE`, AND SAYING SO IS THE
    POINT: ECMA-376 defines `ISO.CEILING` and Excel documents
    `CEILING.PRECISE` with identical wording, so the honest implementation is
    the SAME KERNEL and not a second one that might drift. What it is NOT is
    `CEILING`, whose direction comes from SIGN AGREEMENT:
    `ISO.CEILING(-2.1, -1)` is **-2** where `CEILING(-2.1, -1)` is -3. A row
    wired to `CEILING` answers -3 there and answers 3 for `(2.1, 1)` — the
    positive cell every fixture starts with — so only the negative cell tells
    the two apart."""
    return xl_ceiling_precise(args)


# =============================================================================
# ⭐ ROMAN / ARABIC — a TEXT answer and an INTEGER one, both exact.
# =============================================================================
comptime _MULTINOMIAL_MAX: Float64 = 1.7e308
"""The refusal threshold for `MULTINOMIAL`'s running product. ⚠ BELOW the
binary64 ceiling on purpose: `FormulaValue.number` would turn an overflow into
`#NUM!` anyway, but catching it in the loop means the refusal is attributable to
THIS function rather than to a render-layer guard."""


def _roman_classic(n: Int) -> String:
    """`n` (1..3999) in CLASSIC roman numerals — `form` 0, Excel's default.

    ⚠ THE SUBTRACTIVE PAIRS ARE TABLE ENTRIES, NOT A SPECIAL CASE. A greedy
    kernel over only I V X L C D M renders 4 as `IIII` and 9 as `VIIII`, which
    is a real historical convention and is NOT what Excel's form 0 emits."""
    var vals = List[Int]()
    var syms = List[String]()
    vals.append(1000); syms.append(String("M"))
    vals.append(900); syms.append(String("CM"))
    vals.append(500); syms.append(String("D"))
    vals.append(400); syms.append(String("CD"))
    vals.append(100); syms.append(String("C"))
    vals.append(90); syms.append(String("XC"))
    vals.append(50); syms.append(String("L"))
    vals.append(40); syms.append(String("XL"))
    vals.append(10); syms.append(String("X"))
    vals.append(9); syms.append(String("IX"))
    vals.append(5); syms.append(String("V"))
    vals.append(4); syms.append(String("IV"))
    vals.append(1); syms.append(String("I"))
    var out = String("")
    var rest = n
    for i in range(len(vals)):
        while rest >= vals[i]:
            out += syms[i]
            rest -= vals[i]
    return out^


def xl_roman(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ROMAN(number, [form])` — the CLASSIC (form 0) roman numeral, as TEXT.

    ⚠ `ROMAN(0)` IS THE EMPTY STRING, not `#NUM!` and not `"N"`. A negative
    argument, or one above 3999, IS `#NUM!`.

    ⛔ FORMS 1..4 ARE REFUSED WITH `#VALUE!`, AND THE REFUSAL IS THE HONEST
    ANSWER RATHER THAN THE LAZY ONE. Excel's `form` argument selects one of
    five progressively more CONCISE renderings — `ROMAN(499)` is `CDXCIX` at
    form 0, `LDVLIV` at 1, `XDIX` at 2, `VDIV` at 3 and `ID` at 4 — and each
    concise form has its own subtraction rules, which is a table nobody can
    verify against a live Excel from here. A kernel that accepted the argument
    and rendered form 0 anyway would return a CONFIDENT WRONG STRING for every
    non-zero form; a kernel that ignored the argument would do the same thing
    silently. This is `_weekday_note`'s return-type argument, applied to the
    one function where the default form is unambiguous and complete on its own.
    ⚠ `form` = FALSE coerces to 0 and IS served; Excel treats FALSE as form 4,
    which is a documented DIVERGENCE and not an accident — see `_roman_note`."""
    var x = _num(args, 0)
    if x.is_error():
        return x^
    if len(args) >= 2:
        var f = _num(args, 1)
        if f.is_error():
            return f^
        if _trunc_toward_zero(f.num) != 0.0:
            return FormulaValue.error(XL_ERR_VALUE)
    var t = _trunc_toward_zero(x.num)
    if t < 0.0 or t > 3999.0:
        return FormulaValue.error(XL_ERR_NUM)
    return FormulaValue.text_val(_roman_classic(Int(t)))


def _roman_digit(c: UInt8) -> Int:
    """One roman letter's value, or 0 for anything else. UPPER-CASE ONLY —
    the caller upper-cases first."""
    if c == UInt8(ord("I")):
        return 1
    if c == UInt8(ord("V")):
        return 5
    if c == UInt8(ord("X")):
        return 10
    if c == UInt8(ord("L")):
        return 50
    if c == UInt8(ord("C")):
        return 100
    if c == UInt8(ord("D")):
        return 500
    if c == UInt8(ord("M")):
        return 1000
    return 0


def xl_arabic(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`ARABIC(text)` — a roman numeral back to an integer.

    ⛔ IT IS NOT THE INVERSE OF `ROMAN` AND MUST NOT BE WRITTEN AS ONE. Excel's
    ARABIC accepts every CONCISE form too — `ARABIC("ID")` is 499, which
    `ROMAN(499)` never emits — so a kernel that round-tripped through a
    canonical renderer would refuse exactly the inputs this function exists to
    read. The rule is positional: a letter worth LESS than one to its right is
    SUBTRACTED, and that single rule reads every form.

    ⚠ A LEADING `-` IS ACCEPTED (Excel's own documented behaviour), the empty
    string is 0, and a non-roman character is `#VALUE!`.

    ⚠ ASCII-ONLY BY CONSTRUCTION, and that is correct here rather than the
    byte-indexing defect it is elsewhere: every roman letter is one ASCII byte,
    so a multi-byte character can only ever be the `#VALUE!` case."""
    if len(args) == 0:
        return FormulaValue.error(XL_ERR_VALUE)
    if args[0].is_error():
        return args[0].copy()
    var tv = args[0].coerce_text()
    if tv.is_error():
        return tv^
    var up = tv.text.upper()
    var b = up.as_bytes()
    var i = 0
    var neg = False
    if len(b) > 0 and b[0] == UInt8(ord("-")):
        neg = True
        i = 1
    var total = 0
    var n = len(b)
    while i < n:
        var v = _roman_digit(b[i])
        if v == 0:
            return FormulaValue.error(XL_ERR_VALUE)
        var nxt = 0
        if i + 1 < n:
            nxt = _roman_digit(b[i + 1])
        if nxt > v:
            total -= v
        else:
            total += v
        i += 1
    if neg:
        total = -total
    return FormulaValue.number(Float64(total))
