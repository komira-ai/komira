# =============================================================================
# EVAL_INCOMPARABLE_LITERAL —
# A VARCHAR COLUMN COMPARED AGAINST A NUMBER ANSWERED THE WHOLE TABLE.
# =============================================================================
#
# ============================== THE DEFECT ===================================
#
# Over a 210-row `lineitem` fixture:
#
#     SELECT count(l_orderkey) AS c FROM t WHERE l_shipmode > 5  ->  {'c': [210]}
#
# 210 is EXACTLY the table's row count.
#
# ⛔ AND THAT IS NOT A DROPPED PREDICATE, WHICH IS THE FIRST THING THIS FILE
# PINS. The
# predicate is not dropped — it is EVALUATED, against a value nobody wrote.
# `_eval_predicate` picks its arm from the COLUMN's Arrow type and the STRING
# arm reads `lit.string_val`; a `ScalarValue` built by `from_int(5)` carries
# `string_val == ""`. So the engine ran `l_shipmode > ''`, which is TRUE for
# every non-empty string. `test_the_empty_string_literal_is_where_210_came_from`
# below is the attribution: the same column against a GENUINE `''` literal
# still selects all 8 rows, so the pre-fix answer was the empty-string
# comparison and not a missing filter node.
#
# ⚠ THE FAMILY, NOT THE SPELLING. Every arm in the comparison ladder and every
# IN-list kernel reads ONE field of `ScalarValue`, chosen from the column type
# alone, and an unpopulated field of a `ScalarValue` reads as a well-formed
# zero — `0`, `0.0`, `""`, `False` — never as an error. So "wrong kind of
# literal" and "the literal is zero" are the same bytes to all of them. The
# legs below sweep the readable-field families in BOTH directions: text column
# vs number/bool, number column vs text/bool, IN-list both ways, and all six
# comparison operators, because `> 5` returns EVERY row while `< 5` returns
# NONE and only one of those two looks wrong to a reader.
#
# =============================== THE ORACLE ==================================
#
# DuckDB v1.5.3. Every
# one of these is an ERROR, so REFUSE is the chosen outcome and COERCE is not:
#
#   VARCHAR > 5      Binder Error: Cannot compare values of type VARCHAR and
#                    type INTEGER_LITERAL - an explicit cast is required
#   VARCHAR > 5.5    Binder Error: ... VARCHAR and type DECIMAL(2,1) ...
#   VARCHAR > true   Binder Error: ... VARCHAR and type BOOLEAN ...
#   VARCHAR = 5      Conversion Error: Could not convert string 'AIR' to INT32
#   INTEGER > 'x'    Conversion Error: Could not convert string 'x' to INT32
#   DOUBLE  > 'x'    Conversion Error: Could not convert string "x" to DECIMAL
#
# ⚠ ONE SHAPE IS NARROWER THAN DuckDB ON PURPOSE: `INTEGER > '2'` ANSWERS in
# DuckDB (it casts a string literal that parses) and is refused here. It is a
# WRONG ANSWER today — `i > '2'` evaluates `i > 0` — so refusing is strictly an
# improvement over what it does now, and inventing a partial coercion would be
# a semantics this engine has nowhere else.
#
# ==================== WHY THE ASSERTION IS ON *THIS* TOKEN ===================
#
# ⛔ `PLAN_WIRE_INCOMPARABLE_LITERAL` ALREADY REFUSES THIS PAIR — on the OTHER
# ingress. `komira_plan_wire.plan_wire_values._refuse_if_incomparable` walks a
# plan arriving through `komira_plan_stream`, which is why the DataFrame
# spellings of the same question were already refused while the SQL ingress —
# a different ingress with no such walk — answered 210. A test asserting on the
# DOOR's wording would therefore still pass with the executor's check replaced
# by `if False`. Every leg here asserts `EVAL_INCOMPARABLE_LITERAL`, which is
# reachable from `literal_arm_domain.refuse_incomparable_literal` and nowhere
# else, AND asserts the door's token is absent.
#
# ======================== WHAT THIS FILE DOES NOT PROVE ======================
#
# * ONE PLAN POSITION. Every leg calls `_eval_predicate` directly. The SQL and
#   plan-wire ingresses are covered by their own end-to-end suites.
# * NOT the col-vs-col mismatch. `_eval_col_vs_col_promoted` already refuses a
#   non-numeric pair by name ("unsupported column type pair"); this file is
#   about a LITERAL, whose field is chosen and read without any such check.
# * NOT a DECIMAL256 or a narrow/unsigned-integer COLUMN — no ingress in this
#   tree produces one, so the controls would assert over a shape nothing sends.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.dictionary_array import StringDictionaryArray
from komira_core.arrow.large_string_array import LargeStringArray
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import (
    Expr,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_compiler.literal_arm_domain import literal_is_readable_by_column


# The token this file is ABOUT, and the one it must not be satisfied by.
comptime TOKEN: String = "EVAL_INCOMPARABLE_LITERAL"
comptime DOOR_TOKEN: String = "PLAN_WIRE_INCOMPARABLE_LITERAL"

# 8 rows, TPC-H `l_shipmode` shaped. Row 3 is the EMPTY STRING on purpose: it
# is the one row a genuine `> ''` comparison excludes, which is what lets the
# attribution leg tell "the engine compared against `''`" apart from "the
# engine kept every row".
def _modes() -> List[String]:
    return [
        String("AIR"),
        String("MAIL"),
        String("SHIP"),
        String(""),
        String("RAIL"),
        String("FOB"),
        String("REG AIR"),
        String("TRUCK"),
    ]


comptime N_ROWS: Int = 8


def _batch(name: String, at: ArrowType, var c0: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(c0^)
    return rbb.build(sb.build())


def _text_batch() raises -> RecordBatch:
    return _batch(
        String("m"),
        ArrowType.STRING,
        Column.from_string(StringArray.from_strings(_modes())),
    )


def _large_text_batch() raises -> RecordBatch:
    return _batch(
        String("m"),
        ArrowType.LARGE_STRING,
        Column.from_large_string(LargeStringArray.from_strings(_modes())),
    )


def _dict_text_batch() raises -> RecordBatch:
    var dict_arr = StringArray.from_strings(_modes())
    var indices = PrimitiveArray[DType.int32].allocate(N_ROWS)
    var idx_ptr = indices._typed_ptr_mut()
    for i in range(N_ROWS):
        (idx_ptr + i)[] = Scalar[DType.int32](i)
    return _batch(
        String("m"),
        ArrowType.DICTIONARY,
        Column.from_dictionary(
            StringDictionaryArray.from_parts(indices^, dict_arr^)
        ),
    )


def _i64_batch() raises -> RecordBatch:
    var l: List[Scalar[DType.int64]] = []
    for i in range(N_ROWS):
        l.append(Scalar[DType.int64](i))
    return _batch(
        String("v"),
        ArrowType.INT64,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(l)
        ),
    )


def _i32_batch() raises -> RecordBatch:
    var l: List[Scalar[DType.int32]] = []
    for i in range(N_ROWS):
        l.append(Scalar[DType.int32](i))
    return _batch(
        String("v"),
        ArrowType.INT32,
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(l)
        ),
    )


def _f64_batch() raises -> RecordBatch:
    var l: List[Scalar[DType.float64]] = []
    for i in range(N_ROWS):
        l.append(Scalar[DType.float64](Float64(i)))
    return _batch(
        String("v"),
        ArrowType.FLOAT64,
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(l)
        ),
    )


def _cmp(batch: RecordBatch, name: String, op: UInt8, var v: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(name), Expr.literal(v^))


def _assert_refused(batch: RecordBatch, var e: Expr, what: String) raises:
    """The predicate REFUSES, and it refuses with the EXECUTOR's own token."""
    var raised = False
    var msg = String("")
    try:
        var _m = _eval_predicate(e, batch)
    except err:
        raised = True
        msg = String(err)
    assert_true(raised, what + ": refused rather than answered")
    assert_true(
        TOKEN in msg,
        what + ": names " + TOKEN + " -- got: " + msg,
    )
    # ⛔ The door refuses the same pair on the plan-wire ingress in nearly the
    # same words. If THIS is what came back, the executor's gate did nothing.
    assert_false(
        DOOR_TOKEN in msg,
        what + ": is the EXECUTOR's refusal, not the door's -- got: " + msg,
    )


def _true_count(m: BooleanArray) raises -> Int:
    var n = 0
    for i in range(m.length):
        if m.get(i):
            n += 1
    return n


def _count(batch: RecordBatch, var e: Expr) raises -> Int:
    return _true_count(_eval_predicate(e, batch))


# =============================================================================
# ★ THE TIMESTAMP-UNIT LEG — a column whose TICK is not the literal's
# =============================================================================
#
# `_temporal_literal_i64` reads a timestamp literal out of `ts_micros`, and
# `_eval_temporal_col_vs_literal` reads the COLUMN with `as_primitive[int64]`
# — RAW TICKS, no normalisation. So for a `timestamp[ms]` column the literal's
# micros and the column's millis are numbers in DIFFERENT UNITS, and comparing
# them directly is wrong by 1000x while raising nothing.
#
# ⛔ THE OLD CODE REFUSED THE WHOLE PAIR ("needs unit alignment (follow-up)"),
# which is safe and also declined a question with exactly one right answer:
# a literal ON the column's tick boundary, and left several DataFrame front
# ends unable to express a datetime literal for that column type at all.
#
# ⚠ THE TWO CASES MUST BE TESTED TOGETHER OR NEITHER IS TESTED. "It answers"
# alone passes on a truncating conversion; "it refuses" alone passes on the
# unconditional raise that was there before. The pair — EXACT answers, INEXACT
# still refuses — is the only statement that pins the behaviour.
#
# The fixture is 8 rows at whole SECONDS from the epoch, so every row's value
# is exact in s / ms / us / ns alike and the arithmetic below is checkable by
# hand: row i is i seconds after 1970-01-01T00:00:00Z.
comptime _US_PER_S: Int64 = 1_000_000
comptime _MS_PER_S: Int64 = 1_000


def _ts_batch(at: ArrowType, ticks_per_s: Int64) raises -> RecordBatch:
    """8 rows, row i = i SECONDS after the epoch, stored in `at`'s own tick.

    ⛔⛔ THE TAG GOES ON THE **COLUMN**, NOT ONLY ON THE SCHEMA FIELD — AND
    WRITING IT ONLY ON THE FIELD IS WHY THE FIRST VERSION OF THIS FIXTURE
    MEASURED THE WRONG THING. `_eval_predicate` reads `col_ptr.arrow_type`
    (`compiler_eval_predicate.mojo:1651`), i.e. the COLUMN's own tag; the
    `Field` in the schema is never consulted on this path. So a batch whose
    Field said `timestamp[ms]` while `Column.from_primitive[int64]` stamped
    `ArrowType.INT64` reached the temporal arm anyway — via
    `lit_val.is_timestamp`, the OTHER half of that dispatch — with
    `col_at == INT64`, which lands in `_temporal_literal_i64`'s `else` and
    returns the literal's RAW MICROS with no unit conversion at all.

    ⚠ AND IT FAILED SILENTLY IN BOTH DIRECTIONS, which is why this is written
    down: against the fixed kernel, `t > 5s` over the
    mis-tagged batch answered 0 rows for `timestamp[s]`/`timestamp[ms]` (the
    5_000_000 us threshold is past every tick) and 7 rows for `timestamp[ns]`
    (it is before all but the first) — never an error. The `timestamp[us]`
    case PASSED, because raw micros happens to be the right threshold there,
    so the one leg that could not detect the mistake was the control.

    `from_primitive_with_arrow_type` is the constructor that stamps it. Every
    TIMESTAMP_* is int64-physical, so the backing width matches its tag here;
    a tag stamped over a NARROWER backing is a different hazard
    (`Column.as_primitive` windows at `length * size_of(dt)` and answers
    garbage rather than raising)."""
    var l: List[Scalar[DType.int64]] = []
    for i in range(N_ROWS):
        l.append(Scalar[DType.int64](Int64(i) * ticks_per_s))
    return _batch(
        String("t"),
        at,
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(l), at
        ),
    )


# =============================================================================
# THE DEFECT
# =============================================================================


def test_text_column_vs_int_literal_is_refused_all_six_ops() raises:
    """`l_shipmode OP 5`. `>` answered EVERY row; `<` answers NONE. Both wrong.
    """
    var ops: List[UInt8] = [BIN_GT, BIN_LT, BIN_EQ, BIN_NE, BIN_GE, BIN_LE]
    var names: List[String] = [
        String(">"), String("<"), String("="),
        String("<>"), String(">="), String("<="),
    ]
    for i in range(len(ops)):
        var batch = _text_batch()
        _assert_refused(
            batch,
            _cmp(batch, String("m"), ops[i], ScalarValue.from_int(5)),
            String("STRING column ") + names[i] + String(" 5"),
        )
        _ = batch^


def test_text_column_vs_float_and_bool_literals_are_refused() raises:
    var b1 = _text_batch()
    _assert_refused(
        b1,
        _cmp(b1, String("m"), BIN_GT, ScalarValue.from_float(5.5)),
        String("STRING column > 5.5"),
    )
    _ = b1^
    var b2 = _text_batch()
    _assert_refused(
        b2,
        _cmp(b2, String("m"), BIN_GT, ScalarValue.from_bool(True)),
        String("STRING column > TRUE"),
    )
    _ = b2^


def test_large_string_and_dictionary_text_columns_are_refused_too() raises:
    """The other two arms that read `string_val`. Same defect, same fix."""
    var b1 = _large_text_batch()
    _assert_refused(
        b1,
        _cmp(b1, String("m"), BIN_GT, ScalarValue.from_int(5)),
        String("LARGE_STRING column > 5"),
    )
    _ = b1^
    var b2 = _dict_text_batch()
    _assert_refused(
        b2,
        _cmp(b2, String("m"), BIN_GT, ScalarValue.from_int(5)),
        String("string DICTIONARY column > 5"),
    )
    _ = b2^


def test_numeric_columns_vs_string_literal_are_refused() raises:
    """The MIRROR direction: the int arms read `int_val`, which is 0 for a
    string literal, so `v > 'AIR'` silently became `v > 0`."""
    var b1 = _i64_batch()
    _assert_refused(
        b1,
        _cmp(b1, String("v"), BIN_GT, ScalarValue.from_string(String("AIR"))),
        String("INT64 column > 'AIR'"),
    )
    _ = b1^
    var b2 = _i32_batch()
    _assert_refused(
        b2,
        _cmp(b2, String("v"), BIN_GT, ScalarValue.from_string(String("AIR"))),
        String("INT32 column > 'AIR'"),
    )
    _ = b2^
    var b3 = _f64_batch()
    _assert_refused(
        b3,
        _cmp(b3, String("v"), BIN_GT, ScalarValue.from_string(String("AIR"))),
        String("FLOAT64 column > 'AIR'"),
    )
    _ = b3^


def test_in_list_text_column_vs_number_members_is_refused() raises:
    """The IN-list spelling of the same defect, and it is NOT loud either.

    `_eval_in_list_string` pre-extracts its value table by reading
    `values[i].string_val`, so `m IN (1, 2)` built `["", ""]` and selected
    exactly the EMPTY-STRING rows — ONE row of eight here, which reads as a
    plausible answer rather than as the type error DuckDB raises."""
    var b = _text_batch()
    var vals: List[ScalarValue] = [
        ScalarValue.from_int(1), ScalarValue.from_int(2)
    ]
    _assert_refused(
        b,
        Expr.in_list_node(Expr.col_ref(String("m")), vals^),
        String("STRING column IN (1, 2)"),
    )
    _ = b^


def test_in_list_numeric_column_vs_text_member_is_refused() raises:
    """One bad member in an otherwise legal list is enough. The check is PER
    MEMBER because `IN` is a disjunction and a single unreadable operand is a
    disjunct nobody can evaluate."""
    var b = _i64_batch()
    var vals: List[ScalarValue] = [
        ScalarValue.from_int(2), ScalarValue.from_string(String("AIR"))
    ]
    _assert_refused(
        b,
        Expr.in_list_node(Expr.col_ref(String("v")), vals^),
        String("INT64 column IN (2, 'AIR')"),
    )
    _ = b^


def test_control_in_list_same_type_members_still_evaluate() raises:
    var b1 = _text_batch()
    var sv: List[ScalarValue] = [
        ScalarValue.from_string(String("AIR")),
        ScalarValue.from_string(String("MAIL")),
    ]
    assert_equal(
        _count(b1, Expr.in_list_node(Expr.col_ref(String("m")), sv^)),
        2, "`m IN ('AIR','MAIL')` still matches two rows",
    )
    _ = b1^
    var b2 = _i64_batch()
    var iv: List[ScalarValue] = [
        ScalarValue.from_int(2), ScalarValue.from_int(5)
    ]
    assert_equal(
        _count(b2, Expr.in_list_node(Expr.col_ref(String("v")), iv^)),
        2, "`v IN (2,5)` still matches two rows",
    )
    _ = b2^


def test_numeric_column_vs_bool_literal_is_refused() raises:
    """`id > TRUE` became `id > 0`. The plan-wire door has refused this since
    ; the executor did not, so only one ingress was covered."""
    var b = _i64_batch()
    _assert_refused(
        b,
        _cmp(b, String("v"), BIN_GT, ScalarValue.from_bool(True)),
        String("INT64 column > TRUE"),
    )
    _ = b^


# =============================================================================
# THE ATTRIBUTION — why 210 was an EMPTY-STRING COMPARE and not a dropped node
# =============================================================================


def test_the_empty_string_literal_is_where_210_came_from() raises:
    """A GENUINE `''` literal still selects every non-empty row.

    ⚠ THIS LEG MUST NOT BE 'FIXED' INTO A REFUSAL. `m > ''` is a legal
    comparison of two strings, DuckDB answers it, and it is the control that
    attributes the pre-fix `count = 210` to `lit.string_val == ""` rather than
    to a missing filter. Row 3 IS the empty string, so the answer is N-1 and
    not N — a leg that returned N would be consistent with 'the predicate was
    dropped' and prove nothing."""
    var b = _text_batch()
    var got = _count(b, _cmp(b, String("m"), BIN_GT, ScalarValue.from_string(String(""))))
    assert_equal(got, N_ROWS - 1, "`m > ''` keeps every non-empty row")
    _ = b^


# =============================================================================
# THE CONTROLS — what must STILL WORK
# =============================================================================


def test_control_text_column_vs_string_literal_still_evaluates() raises:
    var b = _text_batch()
    var got = _count(b, _cmp(b, String("m"), BIN_EQ, ScalarValue.from_string(String("MAIL"))))
    assert_equal(got, 1, "`m = 'MAIL'` still matches its one row")
    _ = b^


def test_control_dictionary_text_column_vs_string_literal_still_evaluates() raises:
    var b = _dict_text_batch()
    var got = _count(b, _cmp(b, String("m"), BIN_EQ, ScalarValue.from_string(String("SHIP"))))
    assert_equal(got, 1, "dict `m = 'SHIP'` still matches its one row")
    _ = b^


def test_control_numeric_columns_vs_numeric_literals_still_evaluate() raises:
    """Includes BOTH promotion directions, which sit ABOVE the new gate and
    must keep reaching it: INT column vs FLOAT literal and FLOAT column vs INT
    literal."""
    var b1 = _i64_batch()
    assert_equal(
        _count(b1, _cmp(b1, String("v"), BIN_GT, ScalarValue.from_int(5))),
        2, "`v > 5` over 0..7",
    )
    _ = b1^
    var b2 = _i64_batch()
    assert_equal(
        _count(b2, _cmp(b2, String("v"), BIN_GT, ScalarValue.from_float(5.5))),
        2, "INT64 column vs FLOAT literal still promotes",
    )
    _ = b2^
    var b3 = _f64_batch()
    assert_equal(
        _count(b3, _cmp(b3, String("v"), BIN_GT, ScalarValue.from_int(5))),
        2, "FLOAT64 column vs INT literal still promotes",
    )
    _ = b3^
    var b4 = _i32_batch()
    assert_equal(
        _count(b4, _cmp(b4, String("v"), BIN_LT, ScalarValue.from_int(3))),
        3, "INT32 column vs INT literal",
    )
    _ = b4^


def test_control_null_literal_still_drops_every_row() raises:
    """`col OP NULL` is UNKNOWN for every row under 3VL and has its own arm
    ABOVE the gate. Judging a NULL by TYPE
    would refuse a shape that is expressible and correct."""
    var b = _text_batch()
    assert_equal(
        _count(b, _cmp(b, String("m"), BIN_GT, ScalarValue())),
        0, "`m > NULL` drops every row rather than refusing",
    )
    _ = b^


# =============================================================================
# THE RULE ITSELF — the table, asserted directly
# =============================================================================


def test_readable_field_rule_admits_and_refuses_the_right_pairs() raises:
    """The pair table, at the function the two call sites share.

    ⚠ A TEMPORAL COLUMN ADMITS AN INTEGER LITERAL and that is not an oversight:
    a DATE32 column is physically int32 days-since-epoch and
    `_temporal_literal_i64` has an explicit `is_int` branch. The plan-wire
    door REFUSED that pair once and deleted a working query
    (`plan_wire_values._temporal_column_reads_int_literal` carries the
    measurement)."""
    assert_true(
        literal_is_readable_by_column(
            ArrowType.STRING, ScalarValue.from_string(String("A")), False
        ), "text column, text literal",
    )
    assert_false(
        literal_is_readable_by_column(
            ArrowType.STRING, ScalarValue.from_int(5), False
        ), "text column, int literal",
    )
    assert_true(
        literal_is_readable_by_column(
            ArrowType.INT64, ScalarValue.from_int(5), False
        ), "number column, int literal",
    )
    assert_false(
        literal_is_readable_by_column(
            ArrowType.INT64, ScalarValue.from_string(String("A")), False
        ), "number column, text literal",
    )
    assert_true(
        literal_is_readable_by_column(
            ArrowType.DATE32, ScalarValue.from_int(20456), False
        ), "temporal column, int literal -- ADMITTED, see the docstring",
    )
    assert_true(
        literal_is_readable_by_column(
            ArrowType.STRING, ScalarValue(), False
        ), "a NULL literal is never judged by type",
    )
    # A DICTIONARY column is a TEXT arm or a NUMBER arm depending on the flag
    # the Arrow type alone cannot carry.
    assert_true(
        literal_is_readable_by_column(
            ArrowType.DICTIONARY, ScalarValue.from_string(String("A")), False
        ), "string DICTIONARY, text literal",
    )
    assert_false(
        literal_is_readable_by_column(
            ArrowType.DICTIONARY, ScalarValue.from_int(5), False
        ), "string DICTIONARY, int literal",
    )
    assert_true(
        literal_is_readable_by_column(
            ArrowType.DICTIONARY, ScalarValue.from_int(5), True
        ), "numeric DICTIONARY, int literal",
    )
    assert_false(
        literal_is_readable_by_column(
            ArrowType.DICTIONARY, ScalarValue.from_string(String("A")), True
        ), "numeric DICTIONARY, text literal",
    )
    # A column type with no arm at all is NOT judged here -- the caller's own
    # `else: raise` owns that message, and saying it twice differently would
    # make an envelope limit look like a type error.
    assert_true(
        literal_is_readable_by_column(
            ArrowType.LIST, ScalarValue.from_int(5), False
        ), "an unarmed column type is not judged by this rule",
    )


def test_ts_micros_literal_vs_a_MILLI_column_answers_when_it_is_exact() raises:
    """`t > 5s` over a `timestamp[ms]` column, spelled as a MICROS literal.

    Pre-fix this RAISED "needs unit alignment (follow-up)". The right answer is
    2 (rows 6 and 7 of 0..7 seconds), and it is the SAME 2 the identical
    question gets over a `timestamp[us]` column — which is the point: an exact
    unit conversion does not change the question."""
    var b = _ts_batch(ArrowType.TIMESTAMP_MS, _MS_PER_S)
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S),
            ),
        ),
        2,
        "`t > 5s` over timestamp[ms] selects rows 6,7",
    )
    _ = b^


def test_ts_micros_literal_vs_a_MILLI_column_is_EQ_exact_too() raises:
    """`=` is the operator a rounding conversion would get wrong first: it
    matches AT MOST one row, so an off-by-one-tick threshold shows up as 0
    instead of as a shifted boundary."""
    var b = _ts_batch(ArrowType.TIMESTAMP_MS, _MS_PER_S)
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_EQ,
                ScalarValue.timestamp_micros(Int64(3) * _US_PER_S),
            ),
        ),
        1,
        "`t = 3s` over timestamp[ms] matches exactly row 3",
    )
    _ = b^


def test_ts_micros_literal_vs_a_SECOND_column_answers_when_it_is_exact() raises:
    """The same, at the 1_000_000 divisor — a SECOND column. Included because
    the two divisors are separate arms and one of them could be missed."""
    var b = _ts_batch(ArrowType.TIMESTAMP_S, Int64(1))
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S),
            ),
        ),
        2,
        "`t > 5s` over timestamp[s] selects rows 6,7",
    )
    _ = b^


def _assert_sub_tick_refused(
    at: ArrowType, ticks_per_s: Int64, label: String
) raises:
    """One coarse-tick column, one sub-tick micros literal: REFUSED, by words.

    ⚠ ASSERTED ON THE RAISE AND ON THE WORDS, not on the raise alone: a kernel
    that went back to refusing EVERY coarse-unit pair would pass a bare
    `raised == True`, and that is exactly the pre-fix behaviour."""
    var b = _ts_batch(at, ticks_per_s)
    var raised = False
    var msg = String("")
    try:
        var _n = _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S + 1),
            ),
        )
    except err:
        raised = True
        msg = String(err)
    assert_true(raised, label + ": a sub-tick micros literal is refused")
    assert_true(
        "temporal literal" in msg,
        label + ": the executor's temporal-literal refusal -- got: " + msg,
    )
    assert_true(
        "OPERATOR" in msg and "leftover microseconds" in msg,
        label + ": says WHY there is no single threshold -- got: " + msg,
    )
    _ = b^


def test_a_SUB_TICK_ts_literal_is_still_REFUSED_by_the_executor() raises:
    """⛔ THE HALF THAT MUST NOT BE WIDENED. `5.000001s` has no single threshold
    in a millisecond column: `>` wants floor, `<` wants ceil, and `=` can never
    match. `_temporal_literal_i64` returns ONE Int64 and carries no operator,
    so it refuses — loudly, and saying which of the two cases it is."""
    _assert_sub_tick_refused(
        ArrowType.TIMESTAMP_MS, _MS_PER_S, String("timestamp[ms]")
    )
    _assert_sub_tick_refused(
        ArrowType.TIMESTAMP_S, Int64(1), String("timestamp[s]")
    )


def test_control_ts_micros_literal_vs_a_MICRO_column_still_answers() raises:
    """⭐ THE CONTROL, and it is a claim about the PRE-FIX tree: this arm was
    already correct (`filter/timestamp_us/*@mojo` are GREEN in the
    cross-surface register, which is how the kernel was known to work before
    any of this), so it must pass unchanged. If it reds, the change broke the
    path it was supposed to leave alone and the other legs' greens mean
    nothing."""
    var b = _ts_batch(ArrowType.TIMESTAMP_US, _US_PER_S)
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S),
            ),
        ),
        2,
        "`t > 5s` over timestamp[us] selects rows 6,7",
    )
    _ = b^
    # And a sub-tick literal is NOT refused here — a microsecond column has no
    # coarser tick to align to, so the refusal above must be unit-specific and
    # not a new blanket gate on timestamps.
    var b2 = _ts_batch(ArrowType.TIMESTAMP_US, _US_PER_S)
    assert_equal(
        _count(
            b2,
            _cmp(
                b2,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S + 1),
            ),
        ),
        2,
        "timestamp[us] still answers a sub-millisecond literal",
    )
    _ = b2^


def test_control_ts_micros_literal_vs_a_NANO_column_still_widens() raises:
    """The OTHER pre-existing arm — NS widens by *1000 — must also be
    untouched. It sits in the same ladder the new arms were spliced into."""
    var b = _ts_batch(ArrowType.TIMESTAMP_NS, _US_PER_S * _MS_PER_S)
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(5) * _US_PER_S),
            ),
        ),
        2,
        "`t > 5s` over timestamp[ns] selects rows 6,7",
    )
    _ = b^


def test_a_PRE_EPOCH_ts_literal_narrows_by_FLOOR_not_toward_zero() raises:
    """⚠ MOJO'S `//` FLOORS, so a NEGATIVE exact quotient is the one place an
    'obviously fine' divide can differ from C. -5_000_000 us / 1000 is -5000 ms
    under both rules BECAUSE IT IS EXACT; this pins that the exactness test
    runs BEFORE the divide, rather than a truncation happening to agree.

    Rows are 0..7 seconds AFTER the epoch, so a threshold 5 seconds BEFORE it
    selects all 8."""
    var b = _ts_batch(ArrowType.TIMESTAMP_MS, _MS_PER_S)
    assert_equal(
        _count(
            b,
            _cmp(
                b,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(-5) * _US_PER_S),
            ),
        ),
        8,
        "a pre-epoch ms-exact threshold selects every row",
    )
    _ = b^
    # And the INEXACT pre-epoch literal still refuses, rather than flooring to
    # a threshold one tick low.
    var b2 = _ts_batch(ArrowType.TIMESTAMP_MS, _MS_PER_S)
    var raised = False
    try:
        var _n = _count(
            b2,
            _cmp(
                b2,
                String("t"),
                BIN_GT,
                ScalarValue.timestamp_micros(Int64(-5) * _US_PER_S - 1),
            ),
        )
    except:
        raised = True
    assert_true(raised, "a pre-epoch sub-tick literal is refused too")
    _ = b2^


def main() raises:
    var suite = TestSuite()
    suite.test[test_text_column_vs_int_literal_is_refused_all_six_ops]()
    suite.test[test_text_column_vs_float_and_bool_literals_are_refused]()
    suite.test[test_large_string_and_dictionary_text_columns_are_refused_too]()
    suite.test[test_numeric_columns_vs_string_literal_are_refused]()
    suite.test[test_numeric_column_vs_bool_literal_is_refused]()
    suite.test[test_in_list_text_column_vs_number_members_is_refused]()
    suite.test[test_in_list_numeric_column_vs_text_member_is_refused]()
    suite.test[test_control_in_list_same_type_members_still_evaluate]()
    suite.test[test_the_empty_string_literal_is_where_210_came_from]()
    suite.test[test_control_text_column_vs_string_literal_still_evaluates]()
    suite.test[test_control_dictionary_text_column_vs_string_literal_still_evaluates]()
    suite.test[test_control_numeric_columns_vs_numeric_literals_still_evaluate]()
    suite.test[test_control_null_literal_still_drops_every_row]()
    suite.test[test_readable_field_rule_admits_and_refuses_the_right_pairs]()
    suite.test[test_ts_micros_literal_vs_a_MILLI_column_answers_when_it_is_exact]()
    suite.test[test_ts_micros_literal_vs_a_MILLI_column_is_EQ_exact_too]()
    suite.test[test_ts_micros_literal_vs_a_SECOND_column_answers_when_it_is_exact]()
    suite.test[test_a_SUB_TICK_ts_literal_is_still_REFUSED_by_the_executor]()
    suite.test[test_control_ts_micros_literal_vs_a_MICRO_column_still_answers]()
    suite.test[test_control_ts_micros_literal_vs_a_NANO_column_still_widens]()
    suite.test[test_a_PRE_EPOCH_ts_literal_narrows_by_FLOOR_not_toward_zero]()
    suite^.run()
