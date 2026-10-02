# =============================================================================
# formula_value.mojo — the v1 scalar carrier for Excel formula evaluation
# =============================================================================
#
# `FormulaValue` is a superset of `komira_eval`'s `EvalScalar`: it adds the
# two Excel value-lattice members that SQL's {value, NULL} lacks —
#   - BLANK  (empty cell: coerces to 0 in arithmetic, "" in text; NOT an error,
#            NOT the same as text ""),
#   - ERROR(code)  (first-class error data that PROPAGATES; §3.3 dominance).
#
# Migration (contract §3.4): a `FormulaValue.error(code)` maps 1:1 to Phase-0b's
# columnar `status=ERROR` + sparse sidecar `code` (§3.2 shared enum) — a pure
# code copy, no lossy conversion. When Phase-0b ratifies the shared columnar
# representation, this carrier either retires into an `EvalScalar`-with-error or
# stays as the frontend-local scalar carrier (Phase-0b owns that call).
#
# Encapsulation rule: value semantics only; no UnsafePointer anywhere.
# =============================================================================

from komira_core.plan.excel_error_code import (
    XL_ERR_NONE,
    XL_ERR_NUM,
    XL_ERR_VALUE,
    excel_error_text,
)


# --- The five Excel scalar value kinds. ---
comptime FV_BLANK: UInt8 = 0     # empty cell
comptime FV_NUMBER: UInt8 = 1    # Float64 numeric
comptime FV_TEXT: UInt8 = 2      # String text
comptime FV_LOGICAL: UInt8 = 3   # Bool
comptime FV_ERROR: UInt8 = 4     # error(code)


@fieldwise_init
struct FormulaValue(Copyable, Movable, Writable):
    """One Excel scalar value: number / text / logical / blank / error.

    Only the field matching `kind` is meaningful. Mirrors `EvalScalar` (the
    scalar interpreter's carrier) plus BLANK + ERROR. Constructed via the
    factory staticmethods; never poke fields directly.
    """

    var kind: UInt8
    var num: Float64
    var text: String
    var logical: Bool
    var error_code: UInt8

    # --- Factories ---

    @staticmethod
    @always_inline
    def blank() -> FormulaValue:
        return FormulaValue(FV_BLANK, 0.0, String(""), False, XL_ERR_NONE)

    @staticmethod
    @always_inline
    def number(v: Float64) -> FormulaValue:
        """A NUMBER — or `#NUM!`, because **EXCEL'S NUMERIC LATTICE HAS NO
        INFINITY AND NO NaN** and this is the one place every kernel enters it.

        ⛔⛔ MEASURED 2026-09-14, AND IT WAS SEVEN KERNELS AND NOT ONE.
        `EXP(1000)`, `POWER(10,400)`, `SUMSQ(1e200,1e200)`,
        `PRODUCT(1e200,1e200)`, `SINH(1000)`, `COSH(1000)` and
        `MROUND(1e308,1e-300)` each overflowed to `+inf`, and every one of them
        RENDERED AS `-9223372036854775808` — a plausible finite NEGATIVE
        integer — while `ISNUMBER` answered TRUE on it. That is the worst shape
        a wrong answer can have on this surface: it is not an error, it is not
        `inf`, it does not look like overflow, and it survives every numeric
        guard a caller could write.

        ⚠ THE RENDER WAS NOT THE ROOT CAUSE, ONLY WHERE IT BECAME VISIBLE.
        `_format_number_general` asks `Float64(Int64(v)) == v`, and for a
        non-finite `v` the `Int64(v)` conversion is UNDEFINED — the optimiser is
        entitled to fold the round-trip comparison to TRUE and print the poison
        integer, which is exactly what it did at `--optimization-level 1`. A
        guard added ONLY at the render would leave the `+inf` travelling through
        every comparison, aggregate and `ISNUMBER` above it. So the refusal is
        HERE, at the constructor, which is the one choke point all 174
        construction sites pass through.

        ⚠ `#NUM!` AND NOT `#VALUE!`: Excel's own answer for a computation that
        leaves its numeric range (`=EXP(1000)` in a sheet) is `#NUM!`.

        ⛔ AND THE OLD `_exp_note` ARGUMENT AGAINST THIS — *"it cannot
        distinguish an overflow from a caller who passed +inf in on purpose"* —
        IS UNSOUND, because a caller CANNOT pass `+inf` in on purpose. The
        formula grammar has no infinity literal, `coerce_number` refuses a text
        that parses to one, and no cell value can carry one; the ONLY way a
        non-finite Float64 reaches here is an overflowing computation, which is
        the case Excel calls `#NUM!`."""
        if not _excel_representable(v):
            return FormulaValue(FV_ERROR, 0.0, String(""), False, XL_ERR_NUM)
        return FormulaValue(FV_NUMBER, v, String(""), False, XL_ERR_NONE)

    @staticmethod
    @always_inline
    def text_val(v: String) -> FormulaValue:
        return FormulaValue(FV_TEXT, 0.0, v, False, XL_ERR_NONE)

    @staticmethod
    @always_inline
    def logical_val(v: Bool) -> FormulaValue:
        return FormulaValue(FV_LOGICAL, 0.0, String(""), v, XL_ERR_NONE)

    @staticmethod
    @always_inline
    def error(code: UInt8) -> FormulaValue:
        return FormulaValue(FV_ERROR, 0.0, String(""), False, code)

    # --- Predicates ---

    @always_inline
    def is_error(self) -> Bool:
        return self.kind == FV_ERROR

    @always_inline
    def is_blank(self) -> Bool:
        return self.kind == FV_BLANK

    @always_inline
    def is_number(self) -> Bool:
        return self.kind == FV_NUMBER

    @always_inline
    def is_text(self) -> Bool:
        return self.kind == FV_TEXT

    @always_inline
    def is_logical(self) -> Bool:
        return self.kind == FV_LOGICAL

    # --- Coercions (Excel semantics). Each returns a FormulaValue so an error
    #     can be SIGNALLED (not raised) — the dominance algebra threads errors
    #     as data, never as exceptions. An error input always propagates. ---

    def coerce_logical(self) -> FormulaValue:
        """Coerce to LOGICAL. NUMBER!=0 -> TRUE; BLANK -> FALSE; TEXT "TRUE"/
        "FALSE" (case-insensitive) -> logical, else #VALUE!; ERROR propagates.
        LOGICAL passes through."""
        if self.kind == FV_ERROR:
            return self.copy()
        if self.kind == FV_LOGICAL:
            return self.copy()
        if self.kind == FV_NUMBER:
            return FormulaValue.logical_val(self.num != 0.0)
        if self.kind == FV_BLANK:
            return FormulaValue.logical_val(False)
        # TEXT
        var up = self.text.upper()
        if up == String("TRUE"):
            return FormulaValue.logical_val(True)
        if up == String("FALSE"):
            return FormulaValue.logical_val(False)
        return FormulaValue.error(XL_ERR_VALUE)

    def coerce_text(self) -> FormulaValue:
        """Coerce to TEXT. NUMBER -> general format; LOGICAL -> "TRUE"/"FALSE";
        BLANK -> ""; TEXT passes through; ERROR propagates."""
        if self.kind == FV_ERROR:
            return self.copy()
        if self.kind == FV_TEXT:
            return self.copy()
        if self.kind == FV_BLANK:
            return FormulaValue.text_val(String(""))
        if self.kind == FV_LOGICAL:
            if self.logical:
                return FormulaValue.text_val(String("TRUE"))
            return FormulaValue.text_val(String("FALSE"))
        # NUMBER — "general" format. v1: integral values print without a
        # trailing ".0" (Excel general format); non-integral keep the default.
        # Full Excel general-format rounding is a w2 refinement (documented).
        return FormulaValue.text_val(_format_number_general(self.num))

    def coerce_number(self) -> FormulaValue:
        """Coerce to NUMBER. LOGICAL -> 1/0; BLANK -> 0; NUMBER passes through;
        ERROR propagates. TEXT that parses as a number coerces (Excel implicit
        text->number: `"3"+2 = 5`); non-numeric text (incl. "") -> #VALUE!.

        w2c: this is the scalar-path realization of the profile's coercion
        contract (§2.2). The DECLARATIVE coercion_table + bind-time EXPR_CAST
        insertion is the Expr-lowering / w3 concern (it has no effect on the
        eval-time scalar interpreter, which coerces here); the two agree on the
        RESULT — a numeric-looking text becomes a number in a numeric context."""
        if self.kind == FV_ERROR:
            return self.copy()
        if self.kind == FV_NUMBER:
            return self.copy()
        if self.kind == FV_BLANK:
            return FormulaValue.number(0.0)
        if self.kind == FV_LOGICAL:
            if self.logical:
                return FormulaValue.number(1.0)
            return FormulaValue.number(0.0)
        # TEXT -> parse; non-numeric text (incl. empty) -> #VALUE!.
        # ⚠ AND A TEXT THAT PARSES TO A NON-FINITE DOUBLE IS `#VALUE!`, NOT
        # `#NUM!`. `Float64("inf")` succeeds in Mojo, and Excel's `="inf"+0`
        # is `#VALUE!` — the string is not a number, which is a different
        # complaint from a computation leaving the numeric range. Routing it
        # through `FormulaValue.number` would relabel it `#NUM!` and make the
        # error code a lie about where the value came from.
        try:
            var parsed = Float64(self.text)
            if not _excel_representable(parsed):
                return FormulaValue.error(XL_ERR_VALUE)
            return FormulaValue.number(parsed)
        except:
            return FormulaValue.error(XL_ERR_VALUE)

    # --- Display (Writable + a plain String for golden-test assertions). ---

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.render())

    def render(self) -> String:
        """A stable String rendering for messages + golden-test equality."""
        if self.kind == FV_ERROR:
            return excel_error_text(self.error_code)
        if self.kind == FV_BLANK:
            return String("")
        if self.kind == FV_TEXT:
            return self.text.copy()
        if self.kind == FV_LOGICAL:
            if self.logical:
                return String("TRUE")
            return String("FALSE")
        return _format_number_general(self.num)

    def equals(self, other: FormulaValue) -> Bool:
        """Value equality for golden tests. Same kind + same payload. Error
        equality compares codes; number equality is exact (golden values are
        chosen to be exactly representable)."""
        if self.kind != other.kind:
            return False
        if self.kind == FV_ERROR:
            return self.error_code == other.error_code
        if self.kind == FV_NUMBER:
            return self.num == other.num
        if self.kind == FV_TEXT:
            return self.text == other.text
        if self.kind == FV_LOGICAL:
            return self.logical == other.logical
        # BLANK
        return True


comptime _F64_MAX_FINITE: Float64 = 1.7976931348623157e308
"""The largest finite binary64, which is also the top of Excel's numeric range.

⚠ SPELLED AS A LITERAL rather than imported, because this module is a LEAF of
the import graph by design (see the header) and the constant is exact."""


@always_inline
def _excel_representable(v: Float64) -> Bool:
    """★ IS `v` A VALUE EXCEL COULD HOLD IN A CELL — finite, neither infinity,
    not NaN.

    ⚠ ONE EXPRESSION, AND IT NAMES NEITHER `inf` NOR `NaN` ON PURPOSE. NaN
    fails BOTH comparisons (every ordered comparison against NaN is FALSE), and
    each infinity fails exactly one. A spelling built on `v != v` would be the
    same self-comparison an optimiser is entitled to fold, which is the class of
    defect this function exists to stop."""
    return v >= -_F64_MAX_FINITE and v <= _F64_MAX_FINITE


@always_inline
def _format_number_general(v: Float64) -> String:
    """Excel 'general' number format, v1 subset: integral values print with no
    fractional part; others use the default Float64 rendering. Full general-
    format significant-digit rounding is a w2 refinement.

    ⛔ THE NON-FINITE GUARD IS BELT-AND-BRACES, NOT THE FIX. `Int64(v)` for a
    non-finite `v` is an UNDEFINED conversion, and at `--optimization-level 1`
    the optimiser folded `Float64(Int64(v)) == v` to TRUE and printed the poison
    integer `-9223372036854775808` for seven different overflowing kernels
    (measured 2026-09-14; see `FormulaValue.number`). The REAL fix is that
    `FormulaValue.number` now refuses a non-finite value outright, so no such
    value should ever reach here. This guard is what keeps a future path that
    constructs `FormulaValue(FV_NUMBER, …)` field-wise — which is legal Mojo and
    which this struct does internally — from re-opening it silently.

    ⚠ IT RENDERS THE IEEE SPELLING, NOT A NUMBER. `inf` / `nan` is wrong for a
    sheet, but it is VISIBLY wrong, where a finite negative integer is not."""
    if not _excel_representable(v):
        return String(v)
    var as_int = Int64(v)
    if Float64(as_int) == v:
        return String(as_int)
    return String(v)
