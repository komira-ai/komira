# =============================================================================
# sql/sql_bind_cast.mojo
#   DECIMAL literals and CAST lowering.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from plan_expr.expr import (
    EXPR_ALIAS, EXPR_COL_REF, EXPR_LITERAL, Expr,
)
from plan_expr.expr_walk import (
    PlanColRefFields, walk_expr_field,
)
from plan_expr.scalar_value import ScalarValue
from sql.sql_ast import (
    SX_FLOAT, SX_INT, SX_STRING, SqlExpr,
)
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_ops import _sx_is_big_int
from sql.sql_bind_scope import (
    CteScope, BindScope,
)
from sql.sql_bind_timestamp import _sql_cast_target_arrow
from sql.sql_catalog import SqlCatalog


def _sql_type_name_is_decimal(ty: String) -> Bool:
    """True for the DECIMAL / NUMERIC target-type spellings, parameterised or
    bare. `ty` arrives lower-folded and with its parameters INSIDE the token
    (`decimal(12,2)`), per `_parse_sql_type_name`."""
    return (
        ty == "decimal"
        or ty == "numeric"
        or ty.find("decimal(") == 0
        or ty.find("numeric(") == 0
    )


def _sql_decimal_type_ps(ty: String) raises -> Tuple[Int, Int]:
    """(precision, scale) of a DECIMAL / NUMERIC target-type spelling.

    THE BARE SPELLING IS NOT (0, 0) AND NOT (38, 0) — IN DuckDB
    v1.5.3:

        typeof(CAST('30.75' AS DECIMAL))  -> DECIMAL(18,3)
        typeof(NUMERIC '1')               -> DECIMAL(18,3)
        typeof(CAST('1'     AS DECIMAL(12)))  -> DECIMAL(12,0)

    so a one-parameter spelling means scale 0 and a bare one means (18, 3).
    Reading a bare DECIMAL as (38, 0) — the reflex, since 38 is the width limit
    — would silently TRUNCATE every fractional digit of a value the dialect
    keeps three of.

    THE WIDTH LIMIT IS DUCKDB'S, NOT THIS ENGINE'S ARITHMETIC LIMIT.
    In DuckDB, `CAST('1' AS DECIMAL(39,0))` is a *Binder* Error
    ("DECIMAL type width must be between 1 and 38") there, i.e. the refusal is
    made on the TYPE before any value is seen, which is why it is made here."""
    if ty == "decimal" or ty == "numeric":
        return Tuple[Int, Int](18, 3)
    var lp = ty.find("(")
    var rp = ty.find(")")
    if lp < 0 or rp < 0 or rp < lp:
        raise Error(
            "SQL bind error: malformed DECIMAL type '" + ty.upper() + "'; want"
            " DECIMAL(<precision>) or DECIMAL(<precision>,<scale>)"
        )
    var comma = ty.find(",")
    var precision: Int
    var scale: Int
    if comma < 0 or comma > rp:
        precision = Int(atol(String(ty[byte=lp + 1 : rp])))
        scale = 0
    else:
        precision = Int(atol(String(ty[byte=lp + 1 : comma])))
        scale = Int(atol(String(ty[byte=comma + 1 : rp])))
    if precision < 1 or precision > 38:
        raise Error(
            "SQL not supported: DECIMAL width " + String(precision) + " in '"
            + ty.upper() + "'. A DECIMAL128 holds at most 38 decimal digits,"
            " and DuckDB v1.5.3 refuses the same width at BIND time"
            " (\"DECIMAL type width must be between 1 and 38\")"
        )
    if scale < 0 or scale > precision:
        raise Error(
            "SQL not supported: DECIMAL scale " + String(scale) + " in '"
            + ty.upper() + "'; the scale must be between 0 and the precision"
        )
    return Tuple[Int, Int](precision, scale)


def _decimal_overflow_msg(text: String, ty: String, precision: Int) -> String:
    return (
        "SQL bind error: could not convert string '" + text + "' to "
        + ty.upper() + " — the value needs more than " + String(precision)
        + " decimal digits. DuckDB v1.5.3 raises a Conversion Error on the"
        " same input"
    )


def _decimal_digits_to_i128(
    text: String, precision: Int, scale: Int, ty: String
) raises -> SIMD[DType.int128, 1]:
    """An EXACT decimal spelling -> its UNSCALED i128 value at `scale`.

    THE ROUNDING MODEL IS DuckDB'S, AND IT IS THE THIRD ONE ON
    THIS ENGINE'S CAST SURFACE. DuckDB v1.5.3:

        CAST('30.755'  AS DECIMAL(12,2)) -> 30.76     CAST('30.7449' ..) -> 30.74
        CAST('-30.755' AS DECIMAL(12,2)) -> -30.76    CAST('30.7450' ..) -> 30.75
        CAST('29.999'  AS DECIMAL(12,2)) -> 30.00     CAST('-0.005'  ..) -> -0.01

    i.e. HALF AWAY FROM ZERO. Do NOT implement this by pointing at
    `round_half_to_even` — `CAST(<double> AS BIGINT)` in the same dialect is
    half to EVEN, and the two disagree on exactly the values a test fixture
    tends to use.

    INSPECTING ONE DROPPED DIGIT IS SUFFICIENT AND THAT IS AN ARGUMENT, NOT
    A SHORTCUT: a tail whose first digit is 4 is strictly below one half
    (0.49... < 0.5) and a tail whose first digit is 5 is at least one half, so
    "first dropped digit >= 5 -> step the magnitude up" IS half-away-from-zero
    over the whole tail. Both measured pairs above discriminate it.

    AN EXPONENT SPELLING IS REFUSED RATHER THAN APPROXIMATED. DuckDB accepts
    `CAST('1e2' AS DECIMAL(12,2))` (-> 100.00); this parser does not, and says
    so, because a silently-mis-scaled literal in a PREDICATE changes which rows
    come back and nothing downstream can notice."""
    var b = text.as_bytes()
    var i = 0
    var n = len(b)
    # Leading / trailing ASCII whitespace is accepted (DuckDB accepts
    # `'  30.75 '`), so it is skipped rather than made a parse failure.
    while i < n and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    while n > i and (b[n - 1] == UInt8(32) or b[n - 1] == UInt8(9)):
        n -= 1
    var negative = False
    if i < n and (b[i] == UInt8(ord("-")) or b[i] == UInt8(ord("+"))):
        negative = b[i] == UInt8(ord("-"))
        i += 1
    var int_digits = 0
    # Significant digits accumulated so far (leading zeros do not count). The
    # magnitude is held in an int128, so the width check runs BEFORE each
    # multiply: a value past `precision` digits can never reach the wrap.
    var sig = 0
    var mag = SIMD[DType.int128, 1](0)
    var ten = SIMD[DType.int128, 1](10)
    while i < n and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        var d0 = Int(b[i] - UInt8(ord("0")))
        if sig > 0 or d0 != 0:
            sig += 1
        if sig > precision:
            raise Error(_decimal_overflow_msg(text, ty, precision))
        mag = mag * ten + SIMD[DType.int128, 1](d0)
        int_digits += 1
        i += 1
    var frac_digits = 0
    var kept = 0
    var round_up = False
    if i < n and b[i] == UInt8(ord(".")):
        i += 1
        while i < n and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
            var d = Int(b[i] - UInt8(ord("0")))
            if kept < scale:
                if sig > 0 or d != 0:
                    sig += 1
                if sig > precision:
                    raise Error(_decimal_overflow_msg(text, ty, precision))
                mag = mag * ten + SIMD[DType.int128, 1](d)
                kept += 1
            elif kept == scale and frac_digits == scale:
                # THE FIRST DROPPED DIGIT — see the half-away-from-zero
                # argument in the docstring. Later digits cannot change the
                # verdict and are consumed only so a malformed tail still
                # reaches the syntax check below.
                round_up = d >= 5
            frac_digits += 1
            i += 1
    if int_digits == 0 and frac_digits == 0:
        raise Error(
            "SQL bind error: could not convert string '" + text + "' to "
            + ty.upper() + " — no decimal digits. DuckDB v1.5.3 raises a"
            " Conversion Error on the same input"
        )
    if i < n:
        raise Error(
            "SQL not supported: the decimal literal '" + text + "' is not an"
            " EXACT digit spelling, so CAST to " + ty.upper() + " refuses it"
            " rather than approximating it. DuckDB v1.5.3 DOES accept an"
            " exponent form (CAST('1e2' AS DECIMAL(12,2)) is 100.00); this"
            " binder folds the literal at bind time from its digits alone and"
            " has no exponent scaler, and a mis-scaled literal in a WHERE"
            " clause changes which rows come back with no error anywhere."
            " Write the value out in full."
        )
    # Pad the fraction out to the target scale (`'30.7' AS DECIMAL(12,2)` is
    # 30.70 there, i.e. unscaled 3070).
    while kept < scale:
        if mag != SIMD[DType.int128, 1](0):
            sig += 1
            if sig > precision:
                raise Error(_decimal_overflow_msg(text, ty, precision))
        mag = mag * ten
        kept += 1
    if round_up:
        mag += SIMD[DType.int128, 1](1)
    # OVERFLOW IS CHECKED ON THE ROUNDED VALUE, and the order is measured:
    # `CAST('9999999999.995' AS DECIMAL(12,2))` is a Conversion Error in
    # v1.5.3 — it fits in 12 digits BEFORE rounding and not after.
    var limit = SIMD[DType.int128, 1](1)
    for _p in range(precision):
        limit = limit * ten
    if mag >= limit:
        raise Error(_decimal_overflow_msg(text, ty, precision))
    if negative:
        return -mag
    return mag


def _bind_decimal_literal_cast(
    arg: SqlExpr, ty: String, is_try: Bool
) raises -> Expr:
    """`CAST('<digits>' AS DECIMAL(p,s))` -> one folded DECIMAL128 literal.

    A constant fold, not a cast: `_sql_cast_target_arrow` refuses DECIMAL as a
    cast target because there is no `<numeric column> -> decimal128` cast
    (lowering one to FLOAT64 answers `0.30000000000000004` where DuckDB
    answers `0.3000`). A literal argument needs none: the value is known at
    bind time and `ScalarValue.decimal128_i128` carries it exactly.

    Every other argument shape is refused by name, naming what is missing:
      * a column or any computed expression: no decimal cast;
      * a FLOAT literal: `30.75` reaches this binder as a Float64, and folding
        it exactly would need a binary-float -> decimal formatter graded
        against DuckDB;
      * TRY_CAST: its contract is NULL-on-failure and this fold raises.
    """
    var ps = _sql_decimal_type_ps(ty)
    var precision = ps[0]
    var scale = ps[1]
    if is_try:
        raise Error(
            "SQL not supported: TRY_CAST to " + ty.upper() + ". A DECIMAL"
            " target over a LITERAL is served by CAST — the value is folded at"
            " bind time — but TRY's contract is to answer NULL where the"
            " conversion fails, and a bind-time fold RAISES instead. Use"
            " CAST('<digits>' AS " + ty.upper() + "), which refuses loudly"
            " instead of answering NULL."
        )
    if arg.tag == SX_STRING:
        var v = _decimal_digits_to_i128(String(arg.text), precision, scale, ty)
        return Expr.literal(
            ScalarValue.decimal128_i128(v, precision, scale)
        )
    if arg.tag == SX_INT:
        # Past Int64 the digits ride in `text` (`int_val` is wrapped bits).
        var digits = String(arg.text) if _sx_is_big_int(arg) else String(arg.int_val)
        var v = _decimal_digits_to_i128(digits, precision, scale, ty)
        return Expr.literal(
            ScalarValue.decimal128_i128(v, precision, scale)
        )
    if arg.tag == SX_FLOAT:
        raise Error(
            "SQL not supported: CAST(<float literal> AS " + ty.upper() + ")."
            " A DECIMAL target over an EXACT DIGIT SPELLING is served — write"
            " the value quoted, CAST('" + String(arg.float_val) + "' AS "
            + ty.upper() + ") — but an unquoted literal reaches this binder as"
            " a BINARY Float64, and folding that exactly needs a"
            " float -> decimal FORMATTER graded against DuckDB, which nothing"
            " in this tree has. The nearest wrong answer is the one this"
            " engine refuses everywhere else on this surface: 0.1 + 0.2 as a"
            " DECIMAL(18,4) is 0.3000 there and 0.30000000000000004 through a"
            " float."
        )
    raise Error(
        "SQL not supported: CAST to " + ty.upper() + " over anything but a"
        " LITERAL. The DECIMAL TARGET is not what is missing — a literal"
        " argument is FOLDED at bind time into a DECIMAL128 value that"
        " compares against a DECIMAL128 column — what is missing is a"
        " `<numeric column> -> decimal128` CAST. Lowering one to FLOAT64"
        " would answer 0.30000000000000004 where DuckDB answers 0.3000, so"
        " this refuses instead. Compare against a DECIMAL literal, or cast to"
        " DOUBLE."
    )


def _bind_cast(sx: SqlExpr, is_try: Bool, schema: Schema, scope: BindScope, catalog: SqlCatalog, cte_scope: CteScope, prebound: List[Expr]) raises -> Expr:
    """`CAST(<expr> AS <type>)` / `<expr>::<type>` / `TRY_CAST(...)` -> an
    `EXPR_CAST` node, with the TRY flag for `TRY_CAST`.

    A temporal operand to a number is refused by name, and so is a TRY_CAST
    over a DECIMAL, whose casts raise where TRY_CAST answers NULL.
    """
    ref cargs = sx._call.value().args
    if len(cargs) != 2:
        # UNREACHABLE FROM SQL TEXT — the parser builds both arguments — but
        # stated rather than assumed, because `sx.text` is a name no tokenizer
        # can produce and a future caller reaching this function by any other
        # route is a bug this message names.
        raise Error(
            "SQL bind error: the CAST desugar takes an expression and a type"
            " name; got " + String(len(cargs)) + " argument(s)"
        )
    if cargs[1].tag != SX_STRING:
        raise Error(
            "SQL bind error: the CAST desugar's second argument must be the"
            " target type name as a string literal"
        )
    var ty = String(cargs[1].text)
    # DECIMAL(p,s) over a literal is intercepted before the target table:
    # `_sql_cast_target_arrow` refuses DECIMAL because there is no
    # column-to-decimal128 cast, which is true of a column and not of a
    # literal, which folds at bind time.
    if _sql_type_name_is_decimal(ty):
        return _bind_decimal_literal_cast(cargs[0], ty, is_try)
    var ty_l = ty.lower()
    if (
        not is_try
        and (ty_l == "varchar" or ty_l == "text" or ty_l == "string" or ty_l == "char")
    ):
        # CAST to VARCHAR from an INTEGER / BIGINT / VARCHAR operand: this arm
        # binds the operand and reads its type (which `_sql_cast_target_arrow`
        # cannot). An integer prints as plain decimal, DuckDB v1.5.3's spelling;
        # a VARCHAR operand is the identity. Every other source keeps the
        # refusal below (float formatting is not graded against DuckDB).
        var vchild = _bind_scalar(cargs[0], schema, scope, catalog, cte_scope, prebound)
        var vmissing = String("")
        var vsrc = walk_expr_field[PlanColRefFields](vchild, schema, vmissing).arrow_type
        if vmissing.byte_length() == 0:
            if vsrc == ArrowType.STRING:
                return vchild^
            if vsrc == ArrowType.INT64 or vsrc == ArrowType.INT32:
                return Expr.cast_to_arrow(vchild^, ArrowType.STRING)
    var target = _sql_cast_target_arrow(ty)
    var child = _bind_scalar(cargs[0], schema, scope, catalog, cte_scope, prebound)
    var tmissing = String("")
    var tsrc = walk_expr_field[PlanColRefFields](child, schema, tmissing).arrow_type
    var src_known = tmissing.byte_length() == 0
    # A DATE / TIME / TIMESTAMP / INTERVAL operand to a number is refused by
    # name: DuckDB v1.5.3 has no such cast (`Conversion Error: Unimplemented
    # type for cast (DATE -> BIGINT)`), and a cast here would answer the
    # stored epoch count.
    if src_known and tsrc.is_temporal():
        raise Error(
            "SQL not supported: CAST from a " + String(tsrc) + " value to "
            + ty.upper() + ". DuckDB v1.5.3 has no cast from a DATE, TIME,"
            " TIMESTAMP or INTERVAL to a number (it raises `Conversion Error:"
            " Unimplemented type for cast`, and TRY_CAST answers NULL); this"
            " engine would answer the value's stored epoch count. For a day"
            " count write date_diff('day', DATE '1970-01-01', <date>)."
        )
    # TRY_CAST answers NULL where the cast fails, so it is served only where
    # no failure of the cast below is a wrong number: a STRING operand (the
    # text kernels take the TRY flag), a float (the rounding kernels
    # range-check and take it), BIGINT -> INTEGER (it narrows through a
    # float, below), and every other integer or BOOLEAN cast, which either
    # widens and cannot fail or is not served and raises under CAST and
    # TRY_CAST alike. A DECIMAL operand's casts take no TRY flag: a value
    # past INTEGER raises a Conversion Error where TRY_CAST answers NULL, so
    # it is refused by name.
    if is_try and src_known and tsrc == ArrowType.DECIMAL128:
        raise Error(
            "SQL not supported: TRY_CAST from a DECIMAL value to " + ty.upper()
            + ". TRY_CAST answers NULL where the cast fails, and the cast from"
            " this operand has no NULL-on-failure form here: a value out of"
            " range would raise instead. Use CAST(x AS " + ty.upper() + "),"
            " which raises on the same rows, or TRY_CAST a STRING, a float or"
            " an integer operand."
        )
    # BIGINT -> INTEGER narrows through an exact DOUBLE. A direct INT64 ->
    # INT32 cast keeps the low 32 bits (`CAST(2147483648 AS INTEGER)` would be
    # -2147483648), where DuckDB v1.5.3 raises a Conversion Error. Every INT64
    # value that fits INT32 is exact as a DOUBLE and every one that does not
    # is out of range, and the DOUBLE -> INT32 cast range-checks the raw value,
    # so it raises on exactly the rows DuckDB raises on (TRY: is NULL on
    # them) and answers the same integer everywhere else (its message names
    # DOUBLE where DuckDB's names INT64). Only a provably INT64 operand takes
    # this arm: a DECIMAL rounds half away from zero on its own edge, an
    # INT32 needs no narrowing, and an operand whose type is not visible here
    # keeps the plain cast.
    if target == ArrowType.INT32 and src_known and tsrc == ArrowType.INT64:
        var wide = Expr.cast_to_arrow(child^, ArrowType.FLOAT64)
        if is_try:
            return Expr.try_cast(wide^, DType.int32)
        return Expr.cast_to_arrow(wide^, ArrowType.INT32)
    # A STRING operand reads its text as DuckDB does
    # (`kernels.cast_string_to_number`): `CAST('3.5' AS BIGINT)` is 4 and
    # `CAST('2.5' AS BIGINT)` 3, half away from zero on the first fraction
    # digit — a third rounding model on this cast surface, next to DOUBLE ->
    # BIGINT's half to even — and `CAST('1e3' AS DOUBLE)` is 1000.0.
    if is_try:
        return _try_cast_to(child^, target)
    return Expr.cast_to_arrow(child^, target)


def _try_cast_to(var child: Expr, target: ArrowType) -> Expr:
    """`Expr.try_cast` to one of the four targets `_sql_cast_target_arrow`
    returns (INTEGER, BIGINT, REAL, DOUBLE)."""
    if target == ArrowType.INT32:
        return Expr.try_cast(child^, DType.int32)
    if target == ArrowType.INT64:
        return Expr.try_cast(child^, DType.int64)
    if target == ArrowType.FLOAT32:
        return Expr.try_cast(child^, DType.float32)
    return Expr.try_cast(child^, DType.float64)


def _bound_expr_is_string(e: Expr, schema: Schema) -> Bool:
    """True iff the ALREADY-BOUND value Expr `e` is VISIBLY a STRING.

    IT READS THE **ARROW** TYPE, NOT `Field.dtype`. A STRING field's `dtype`
    is `DTYPE_NONE` — the same value an ABSENT column returns from
    `_col_dtype_by_name`, and the same value a DATE32 field carries — so a
    `dtype == <something>` test here would either match three unrelated things
    or nothing at all. `field_arrow_type` is the only channel that separates
    them.

    CONSERVATIVE ON PURPOSE, AND ONLY USED TO REFUSE. It answers True for the
    two shapes it can see without inference (a string literal, a string column,
    and an alias of either) and False for everything else — so a string
    arriving through a computed shape is not caught at bind and fails in the
    executor instead. That is the fail-LOUD direction. It deliberately does
    NOT answer True for every `EXPR_STRING_FN`: `length(s)` is on that tag and
    returns an INT64 (`string_fn_returns_int`), so a blanket True would refuse
    `nullif(length(a), 3)`, which this engine serves."""
    if e.tag == EXPR_LITERAL:
        return e.literal_value().is_string()
    if e.tag == EXPR_COL_REF:
        return _col_is_string_by_name(schema, e.col_ref_name())
    if e.tag == EXPR_ALIAS:
        return _bound_expr_is_string(e.alias_child_ref(), schema)
    return False


def _col_is_string_by_name(schema: Schema, name: String) -> Bool:
    """True iff `name` is a STRING column of `schema` (case-insensitive)."""
    var t = name.lower()
    for i in range(schema.num_columns()):
        if schema.field_name(i).lower() == t:
            return schema.field_arrow_type(i) == ArrowType.STRING
    return False


