# =============================================================================
# Direct tests of CAST, DECIMAL literals, make_timestamp and TIMESTAMP
# literals (sql_bind_cast, sql_bind_timestamp)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. CAST to VARCHAR is served from an INTEGER / BIGINT / VARCHAR operand
#      (a VARCHAR operand is the identity) and refused from a float; CAST to
#      INTEGER from a BIGINT narrows through an exact DOUBLE; the served
#      targets and their aliases; every other target, TRY_CAST, a string
#      operand and a temporal operand are refused by name.
#      (mutant: the BIGINT -> INTEGER arm casts straight to INT32)
#   2. CAST('<digits>' AS DECIMAL(p,s)) folds to one exact DECIMAL128 literal,
#      rounding half away from zero on the first dropped digit, with the
#      bare spelling meaning (18, 3); overflow after rounding, malformed text,
#      an exponent, a float or column operand, TRY_CAST, a width past 38 and a
#      scale past the precision are refused.
#      (mutant: `round_up` set on a first dropped digit `> 5`)
#   3. make_timestamp / _ms / _ns label an integer tick count with its unit
#      (`_ms` then scales to microseconds); the six-argument overload, a
#      non-integer operand and a wrong count are refused.
#   4. TIMESTAMP / TIMESTAMPTZ literals: separators, partial times, a
#      truncated sub-microsecond tail, `Z` / +HH / -HH:MM / +HHMM offsets,
#      and every malformed shape.
#      (mutant: the offset subtracted with the wrong sign)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from komira_sql.sql_binder import bind_statement


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened); mem(k, v): an empty in-memory table."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return cat^


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: every path but `missing.parquet`
    has schema (k INT64, v FLOAT64); `k` holds no NULL and `v` holds 3; a
    path named `bad.parquet` raises for null counts."""

    def footer_schema(self, path: String) raises -> Schema:
        if path == "missing.parquet":
            raise Error("no such file: " + path)
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad.parquet":
            raise Error("unreadable statistics")
        if column == "k":
            return 0
        if column == "v":
            return 3
        return None


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _gotp(sql: String) raises -> String:
    """`_got` with the `_Footers` reader."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _checkp(sql: String, want: String) raises:
    assert_equal(_gotp(sql), want, sql)

def test_cast_targets() raises:
    _check(
        "SELECT CAST(k AS VARCHAR) AS a, CAST(s AS TEXT) AS b, CAST(i32 AS STRING) AS c FROM t",
        "Project(exprs=[Alias(Cast(ColRef(k), float8_e5m2, arrow=string), \"a\"), Alias(ColRef(s), \"b\"), Alias(Cast(ColRef(i32), float8_e5m2, arrow=string), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CAST(v AS VARCHAR) FROM t",
        "ERR: SQL not supported: CAST to VARCHAR from this operand. Number-to-text FORMATTING has not been graded against DuckDB cell for cell (v1.5.3 prints 1e308 as \"1e+308\", a DECIMAL literal -0.0 as \"0.0\" but a DOUBLE -0.0 as \"-0.0\"), and a text column that differs from DuckDB in one cell is a wrong answer with a success code. CAST (not TRY_CAST) to VARCHAR IS served from an INTEGER / BIGINT / VARCHAR operand -- an integer-to-text CAST cannot fail, so for one TRY_CAST is the same answer. A FLOAT or DECIMAL operand can be cast to BIGINT first, which ROUNDS its fraction away (a different text). A narrower or unsigned integer, a BOOLEAN, a DATE or a TIMESTAMP operand has no remedy at this door: DuckDB refuses CAST(<date> AS BIGINT), and this engine's casts do not reach BIGINT from the others."
    )
    _check(
        "SELECT TRY_CAST(k AS VARCHAR) FROM t",
        "ERR: SQL not supported: CAST to VARCHAR from this operand. Number-to-text FORMATTING has not been graded against DuckDB cell for cell (v1.5.3 prints 1e308 as \"1e+308\", a DECIMAL literal -0.0 as \"0.0\" but a DOUBLE -0.0 as \"-0.0\"), and a text column that differs from DuckDB in one cell is a wrong answer with a success code. CAST (not TRY_CAST) to VARCHAR IS served from an INTEGER / BIGINT / VARCHAR operand -- an integer-to-text CAST cannot fail, so for one TRY_CAST is the same answer. A FLOAT or DECIMAL operand can be cast to BIGINT first, which ROUNDS its fraction away (a different text). A narrower or unsigned integer, a BOOLEAN, a DATE or a TIMESTAMP operand has no remedy at this door: DuckDB refuses CAST(<date> AS BIGINT), and this engine's casts do not reach BIGINT from the others."
    )
    _check(
        "SELECT CAST(k AS INTEGER) AS a, CAST(i32 AS BIGINT) AS b, CAST(k AS REAL) AS c, CAST(k AS DOUBLE) AS d, k::DOUBLE AS e, CAST(k AS float8) AS f, CAST(v AS INT) AS g, CAST(dc AS INTEGER) AS h FROM t",
        "Project(exprs=[Alias(Cast(Cast(ColRef(k), float64), int32), \"a\"), Alias(Cast(ColRef(i32), int64), \"b\"), Alias(Cast(ColRef(k), float32), \"c\"), Alias(Cast(ColRef(k), float64), \"d\"), Alias(Cast(ColRef(k), float64), \"e\"), Alias(Cast(ColRef(k), float64), \"f\"), Alias(Cast(ColRef(v), int32), \"g\"), Alias(Cast(ColRef(dc), int32), \"h\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CAST(k AS BOOLEAN) FROM t",
        "ERR: SQL not supported: CAST to BOOLEAN. This engine converts to INTEGER / BIGINT / REAL / DOUBLE — the four targets its cast kernels reach from every numeric source — and refuses every other target BY NAME rather than approximating it with the nearest one: a CAST that answered a number of the wrong type would be a wrong answer with a success code."
    )
    _check(
        "SELECT CAST(k AS SMALLINT) FROM t",
        "ERR: SQL not supported: CAST to SMALLINT. This engine converts to INTEGER / BIGINT / REAL / DOUBLE — the four targets its cast kernels reach from every numeric source — and refuses every other target BY NAME rather than approximating it with the nearest one: a CAST that answered a number of the wrong type would be a wrong answer with a success code."
    )
    _check(
        "SELECT TRY_CAST(k AS INTEGER) FROM t",
        "ERR: SQL not supported: TRY_CAST. Its contract is to answer NULL where the cast fails, so a gap in the underlying cast becomes an INVISIBLE wrong answer rather than an error. Two known ones: TRY_CAST('3.5' AS BIGINT) is 4 in DuckDB v1.5.3 and would be NULL here (no string parse takes a fractional spelling), and TRY_CAST(<INT64_MIN> AS INTEGER) is NULL there and would not be here (no null-on-overflow arm for a numeric narrowing). Use CAST(x AS INTEGER), which refuses loudly instead."
    )
    _check(
        "SELECT CAST(s AS BIGINT) FROM t",
        "ERR: SQL not supported: CAST from a STRING to BIGINT. What is refused is the ROUNDING: DuckDB v1.5.3 answers 4 for CAST('3.5' AS BIGINT) and 3 for CAST('2.5' AS BIGINT), rounding half AWAY FROM ZERO — a third model, different again from the half-to-even it uses for CAST(<double> AS BIGINT) — and this engine has no string parse with that rounding, so serving this would raise or answer differently where DuckDB answers a number. Convert in your application, or cast a numeric column instead."
    )
    _check(
        "SELECT CAST('3' AS BIGINT) FROM t",
        "ERR: SQL not supported: CAST from a STRING to BIGINT. What is refused is the ROUNDING: DuckDB v1.5.3 answers 4 for CAST('3.5' AS BIGINT) and 3 for CAST('2.5' AS BIGINT), rounding half AWAY FROM ZERO — a third model, different again from the half-to-even it uses for CAST(<double> AS BIGINT) — and this engine has no string parse with that rounding, so serving this would raise or answer differently where DuckDB answers a number. Convert in your application, or cast a numeric column instead."
    )
    _check(
        "SELECT CAST(d AS BIGINT) FROM t",
        "ERR: SQL not supported: CAST from a date32 value to BIGINT. DuckDB v1.5.3 has no cast from a DATE, TIME, TIMESTAMP or INTERVAL to a number (it raises `Conversion Error: Unimplemented type for cast`, and TRY_CAST answers NULL); this engine would answer the value's stored epoch count. For a day count write date_diff('day', DATE '1970-01-01', <date>)."
    )
    _check(
        "SELECT CAST(ts AS DOUBLE) FROM t",
        "ERR: SQL not supported: CAST from a timestamp[us] value to DOUBLE. DuckDB v1.5.3 has no cast from a DATE, TIME, TIMESTAMP or INTERVAL to a number (it raises `Conversion Error: Unimplemented type for cast`, and TRY_CAST answers NULL); this engine would answer the value's stored epoch count. For a day count write date_diff('day', DATE '1970-01-01', <date>)."
    )


def test_decimal_literal_casts() raises:
    _check(
        "SELECT CAST('30.755' AS DECIMAL(12,2)) AS a, CAST('-30.755' AS DECIMAL(12,2)) AS b, CAST('29.999' AS DECIMAL(12,2)) AS c, CAST('30.7449' AS DECIMAL(12,2)) AS e, CAST('  30.75 ' AS DECIMAL) AS f, CAST('+1' AS NUMERIC(5)) AS g, CAST(5 AS DECIMAL(10,2)) AS h, CAST('.5' AS DECIMAL(3,1)) AS i FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(decimal128(12,2), hi=0, lo=3076)), \"a\"), Alias(Literal(ScalarValue(decimal128(12,2), hi=-1, lo=-3076)), \"b\"), Alias(Literal(ScalarValue(decimal128(12,2), hi=0, lo=3000)), \"c\"), Alias(Literal(ScalarValue(decimal128(12,2), hi=0, lo=3074)), \"e\"), Alias(Literal(ScalarValue(decimal128(18,3), hi=0, lo=30750)), \"f\"), Alias(Literal(ScalarValue(decimal128(5,0), hi=0, lo=1)), \"g\"), Alias(Literal(ScalarValue(decimal128(10,2), hi=0, lo=500)), \"h\"), Alias(Literal(ScalarValue(decimal128(3,1), hi=0, lo=5)), \"i\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT CAST(18446744073709551615 AS DECIMAL(38,0)) AS a FROM t",
        "Project(exprs=[Alias(Literal(ScalarValue(decimal128(38,0), hi=0, lo=-1)), \"a\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT dc = CAST('1.50' AS DECIMAL(12,2)) AS e FROM t",
        "Project(exprs=[Alias(BinaryOp(EQ, ColRef(dc), Literal(ScalarValue(decimal128(12,2), hi=0, lo=150))), \"e\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_decimal_literal_refusals() raises:
    _check(
        "SELECT CAST('9999999999.995' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL bind error: could not convert string '9999999999.995' to DECIMAL(12,2) — the value needs more than 12 decimal digits. DuckDB v1.5.3 raises a Conversion Error on the same input"
    )
    _check(
        "SELECT CAST('1e2' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL not supported: the decimal literal '1e2' is not an EXACT digit spelling, so CAST to DECIMAL(12,2) refuses it rather than approximating it. ⚠ DuckDB v1.5.3 DOES accept an exponent form (CAST('1e2' AS DECIMAL(12,2)) is 100.00); this binder folds the literal at bind time from its digits alone and has no exponent scaler, and a mis-scaled literal in a WHERE clause changes which rows come back with no error anywhere. Write the value out in full."
    )
    _check(
        "SELECT CAST('abc' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL bind error: could not convert string 'abc' to DECIMAL(12,2) — no decimal digits. DuckDB v1.5.3 raises a Conversion Error on the same input"
    )
    _check(
        "SELECT CAST('' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL bind error: could not convert string '' to DECIMAL(12,2) — no decimal digits. DuckDB v1.5.3 raises a Conversion Error on the same input"
    )
    _check(
        "SELECT CAST('1.2.3' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL not supported: the decimal literal '1.2.3' is not an EXACT digit spelling, so CAST to DECIMAL(12,2) refuses it rather than approximating it. ⚠ DuckDB v1.5.3 DOES accept an exponent form (CAST('1e2' AS DECIMAL(12,2)) is 100.00); this binder folds the literal at bind time from its digits alone and has no exponent scaler, and a mis-scaled literal in a WHERE clause changes which rows come back with no error anywhere. Write the value out in full."
    )
    _check(
        "SELECT CAST('-' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL bind error: could not convert string '-' to DECIMAL(12,2) — no decimal digits. DuckDB v1.5.3 raises a Conversion Error on the same input"
    )
    _check(
        "SELECT CAST(1.5 AS DECIMAL(12,2)) FROM t",
        "ERR: SQL not supported: CAST(<float literal> AS DECIMAL(12,2)). A DECIMAL target over an EXACT DIGIT SPELLING is served — write the value quoted, CAST('1.5' AS DECIMAL(12,2)) — but an unquoted literal reaches this binder as a BINARY Float64, and folding that exactly needs a float -> decimal FORMATTER graded against DuckDB, which nothing in this tree has. The nearest wrong answer is the one this engine refuses everywhere else on this surface: 0.1 + 0.2 as a DECIMAL(18,4) is 0.3000 there and 0.30000000000000004 through a float."
    )
    _check(
        "SELECT CAST(k AS DECIMAL(12,2)) FROM t",
        "ERR: SQL not supported: CAST to DECIMAL(12,2) over anything but a LITERAL. ⚠ The DECIMAL TARGET is not what is missing — a literal argument is FOLDED at bind time into a DECIMAL128 value that compares against a DECIMAL128 column — what is missing is a `<numeric column> -> decimal128` CAST. Lowering one to FLOAT64 would answer 0.30000000000000004 where DuckDB answers 0.3000, so this refuses instead. Compare against a DECIMAL literal, or cast to DOUBLE."
    )
    _check(
        "SELECT TRY_CAST('1' AS DECIMAL(12,2)) FROM t",
        "ERR: SQL not supported: TRY_CAST to DECIMAL(12,2). A DECIMAL target over a LITERAL is served by CAST — the value is folded at bind time — but TRY's contract is to answer NULL where the conversion fails, and a bind-time fold RAISES instead. Use CAST('<digits>' AS DECIMAL(12,2)), which refuses loudly instead of answering NULL."
    )
    _check(
        "SELECT CAST('1' AS DECIMAL(39,0)) FROM t",
        "ERR: SQL not supported: DECIMAL width 39 in 'DECIMAL(39,0)'. A DECIMAL128 holds at most 38 decimal digits, and DuckDB v1.5.3 refuses the same width at BIND time (\"DECIMAL type width must be between 1 and 38\")"
    )
    _check(
        "SELECT CAST('1' AS DECIMAL(5,6)) FROM t",
        "ERR: SQL not supported: DECIMAL scale 6 in 'DECIMAL(5,6)'; the scale must be between 0 and the precision"
    )
    _check(
        "SELECT CAST('1' AS DECIMAL(0)) FROM t",
        "ERR: SQL not supported: DECIMAL width 0 in 'DECIMAL(0)'. A DECIMAL128 holds at most 38 decimal digits, and DuckDB v1.5.3 refuses the same width at BIND time (\"DECIMAL type width must be between 1 and 38\")"
    )
    _check(
        "SELECT CAST('1' AS DECIMAL(5,)) FROM t",
        "Project(exprs=[Literal(ScalarValue(decimal128(5,0), hi=0, lo=1))])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_make_timestamp() raises:
    _check(
        "SELECT make_timestamp(1) AS a, make_timestamp_ms(k) AS b, make_timestamp_ns(i32) AS c FROM t",
        "Project(exprs=[Alias(Cast(Literal(ScalarValue(int64, 1)), int64, arrow=timestamp[us]), \"a\"), Alias(Cast(Cast(ColRef(k), int64, arrow=timestamp[ms]), int64, arrow=timestamp[us]), \"b\"), Alias(Cast(Cast(ColRef(i32), int64), int64, arrow=timestamp[ns]), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT make_timestamp(2024, 10, 4, 12, 0, 0.0) FROM t",
        "ERR: SQL not supported: the SIX-ARGUMENT `make_timestamp(year, month, day, hour, minute, seconds)` MINTS A TEMPORAL VALUE from CALENDAR COMPONENTS, and THE MISSING PRIMITIVE IS CIVIL-CALENDAR-TO-DAYS — month lengths and the Gregorian leap rule — which no `EXPR_*` tag or binder desugar in this engine computes. ⚠ THE ONE-ARGUMENT OVERLOAD OF THE SAME NAME IS SERVED, and the difference is not arity for its own sake: `make_timestamp(<n>)` is a MICROSECOND COUNT SINCE 1970-01-01 (measured DuckDB v1.5.5: `make_timestamp(1)` is `1970-01-01 00:00:00.000001`), i.e. a temporal quantity that only has to be LABELLED, while the six-argument form has to be COMPUTED. ⛔ DO NOT 'FIX' THIS BY LOWERING IT TO THE SAME RELABEL: that reinterprets the YEAR as a microsecond count and answers a wrong instant with a success code. Spell the instant as a microsecond count, or use a TIMESTAMP literal."
    )
    _check(
        "SELECT make_timestamp(v) FROM t",
        "ERR: SQL not supported: `make_timestamp` takes an INTEGER tick count since 1970-01-01, but this argument is of type float64. ⛔ REFUSED RATHER THAN COERCED: the lowering LABELS the operand's own integer as a temporal unit, so a non-integer operand has no correct reading — a floating-point count would have to be rounded (and DuckDB's rounding model for that is not graded in this tree), and a string would have to be PARSED, which is the separate gap `strptime` is refused for. Cast the argument to BIGINT if that is what you meant."
    )
    _check(
        "SELECT make_timestamp(k, k) FROM t",
        "ERR: SQL bind error: `make_timestamp` takes exactly ONE argument here — an INTEGER tick count since 1970-01-01 — but got 2. (DuckDB v1.5.5 also gives `make_timestamp` a six-argument calendar overload; this engine refuses that one by name, because it needs civil-calendar arithmetic this engine does not have.)"
    )
    _check(
        "SELECT make_timestamp_ms() FROM t",
        "ERR: SQL bind error: `make_timestamp_ms` takes exactly ONE argument here — an INTEGER tick count since 1970-01-01 — but got 0. (DuckDB v1.5.5 also gives `make_timestamp` a six-argument calendar overload; this engine refuses that one by name, because it needs civil-calendar arithmetic this engine does not have.)"
    )


def test_timestamp_literals() raises:
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15.123456'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815123456))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01T03:30:15'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471800000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609459200000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15.1234567'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815123456))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '1969-12-31 23:59:59.999999'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], -1))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '  2021-01-01 03:30:15  '",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01t03:30:15'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15.123456Z'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815123456))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15.123456+02'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609464615123456))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15.123456-05:30'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609491615123456))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15.123456+0530'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15.123456+0530': unexpected trailing text '30'"
    )


def test_timestamp_literal_refusals() raises:
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15'",
        "ERR: SQL not supported: TIMESTAMPTZ '2021-01-01 03:30:15' WITHOUT A UTC OFFSET. Its instant depends on a SESSION TIMEZONE, and this engine has none — `ScalarValue` carries no timezone field at all — so there is nothing here that could read the same digits the way DuckDB does (DuckDB v1.5.3 reads these digits with no offset in its session zone). Write the offset: TIMESTAMPTZ '2021-01-01 03:30:15+00'."
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15+02'",
        "ERR: SQL not supported: TIMESTAMP '2021-01-01 03:30:15+02' WITH a UTC offset. ⚠ DuckDB v1.5.3 accepts this and SILENTLY DISCARDS the offset (measured: TIMESTAMP '2021-01-01 03:30:15.123456+02' is the same instant as the same text with no offset). This engine refuses rather than reproducing that, because an offset that changes nothing changes which rows a WHERE clause returns with no diagnostic anywhere. Use TIMESTAMPTZ '2021-01-01 03:30:15+02' to honour the offset, or drop the offset to mean a wall clock."
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01X03'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01X03': expected a space or 'T' after the date, got 'X'"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021'",
        "ERR: SQL bind error: malformed timestamp literal '2021' (want YYYY-MM-DD[ HH:MM[:SS[.ffffff]]])"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15.123456 UTC'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15.123456 UTC': unexpected trailing text ' UTC'"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 25:00:00'",
        "ERR: SQL bind error: timestamp literal '2021-01-01 25:00:00' has a time-of-day field out of range"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:61:00'",
        "ERR: SQL bind error: timestamp literal '2021-01-01 03:61:00' has a time-of-day field out of range"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:61'",
        "ERR: SQL bind error: timestamp literal '2021-01-01 03:30:61' has a time-of-day field out of range"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609470000000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15.'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15.': a '.' with no fractional digits after it"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15 junk'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15 junk': unexpected trailing text ' junk'"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15+25'",
        "ERR: SQL bind error: timestamp literal '2021-01-01 03:30:15+25' has a UTC offset out of range"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15+02:61'",
        "ERR: SQL bind error: timestamp literal '2021-01-01 03:30:15+02:61' has a UTC offset out of range"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15+2'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609464615000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15:16'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15:16': unexpected trailing text ':16'"
    )


def test_timestamp_literal_edge_shapes() raises:
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 :30'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 :30': expected HH:MM[:SS[.ffffff]] after the date"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMP '2021-01-01 03:30:15.5'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609471815500000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15+'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15+': a zone sign with no hours after it"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15+02:'",
        "ERR: SQL bind error: malformed timestamp literal '2021-01-01 03:30:15+02:': a zone with a ':' and no minutes after it"
    )
    _check(
        "SELECT k FROM t WHERE ts = TIMESTAMPTZ '2021-01-01 03:30:15-02'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(ts), Literal(ScalarValue(timestamp[us], 1609479015000000))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
