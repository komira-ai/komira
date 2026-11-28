"""The expression encoder of komira._plan, case by case: each literal kind at
its boundaries, the arms the goldens hold one value of (column sides, the
argument counts of the many-argument string functions, the int32 widening and
decimal arithmetic types), the CASE literal promotion, and every refusal, by
its exact class and full message. test_plan_expr_goldens.py holds the encoder
to plans the engine built.

    test_plan_expr.py
"""

import datetime
import decimal
import sys

from komira._errors import UnsupportedOperation
from komira._ops import (
    Alias,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Extract,
    Lit,
    RoundDigits,
    StringFnN,
    StructField,
    Unary,
    When,
)
from komira._plan import encode_expr, expr_field
from komira.plan.v1 import plan_pb2 as pb
from komira.plan.v1 import plan_vocabulary_pb2 as vocab


def column(name, arrow, nullable=True, **slots):
    """A schema column: `arrow` is the ArrowType member name, e.g. "INT64";
    its dictionary index type is INT32 unless `slots` names another."""
    slots.setdefault("dict_index_type_id", 4)
    return pb.WireField(
        name=name,
        arrow_type_id=getattr(vocab, "ARROW_TYPE_" + arrow) - 1,
        nullable=nullable,
        **slots,
    )


def type_id(arrow):
    return getattr(vocab, "ARROW_TYPE_" + arrow) - 1


SCHEMA = [
    column("a", "INT64", False, dtype_code=vocab._DT_INT64, metadata_keys=["unit"], metadata_values=["cents"]),
    column("b", "INT64", dtype_code=vocab._DT_INT64),
    column("i", "INT32", dtype_code=vocab._DT_INT32),
    column("f", "FLOAT64", dtype_code=vocab._DT_FLOAT64),
    column("d", "DECIMAL128", decimal_precision=12, decimal_scale=2),
    column("s", "STRING"),
    column(
        "st",
        "STRUCT",
        child_names=["k", "v"],
        child_type_ids=[type_id("INT64"), type_id("STRING")],
        child_nullables=[False, True],
    ),
]

A, B, I, F, D, S, ST = (ColRef(n) for n in ("a", "b", "i", "f", "d", "s", "st"))


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def literal(value):
    return encode_expr(Lit(value), SCHEMA).literal


def scalar(**fields):
    """The scalar with `fields`, kind DTYPE and microseconds unless given."""
    fields.setdefault("kind", vocab.SCALAR_KIND_DTYPE)
    fields.setdefault("time_unit", vocab.SCALAR_TIME_UNIT_MICRO)
    return pb.WireScalar(**fields)


def arrow_of(node):
    f = expr_field(node, SCHEMA)
    return vocab.ArrowType.Name(f.arrow_type_id + 1).removeprefix("ARROW_TYPE_")


# ---- literals ---------------------------------------------------------------


def test_int_literals_at_the_edges_of_int64_and_uint64():
    assert literal(0) == scalar(dtype_code=vocab._DT_INT64)
    assert literal(-(2**63)) == scalar(dtype_code=vocab._DT_INT64, int_val=-(2**63))
    assert literal(2**63 - 1) == scalar(dtype_code=vocab._DT_INT64, int_val=2**63 - 1)
    assert literal(2**63) == scalar(dtype_code=vocab._DT_UINT64, int_val=-(2**63))
    assert literal(2**64 - 1) == scalar(dtype_code=vocab._DT_UINT64, int_val=-1)


def test_an_int_outside_int64_and_uint64_is_refused():
    for value in (2**64, -(2**63) - 1):
        refuses(
            lambda: literal(value),
            UnsupportedOperation,
            f"a literal integer {value} cannot be encoded: it is outside int64 and uint64;"
            " pass it as a decimal.Decimal or a float",
        )


def test_bool_float_and_string_literals():
    assert literal(True) == scalar(dtype_code=vocab._DT_BOOL, bool_val=True)
    assert literal(False) == scalar(dtype_code=vocab._DT_BOOL)
    assert literal(-0.0) == scalar(dtype_code=vocab._DT_FLOAT64, float_val=-0.0)
    assert literal("") == scalar(kind=vocab.SCALAR_KIND_STRING)
    assert literal("é") == scalar(kind=vocab.SCALAR_KIND_STRING, string_val="é")
    assert literal(None) == scalar(null_dtype_code=vocab._DT_INT64)


def test_bytes_are_binary_and_bytes_that_are_not_utf8_are_refused():
    assert literal(b"") == scalar(kind=vocab.SCALAR_KIND_BINARY)
    assert literal(b"\xc3\xa9") == scalar(kind=vocab.SCALAR_KIND_BINARY, string_val="é")
    refuses(
        lambda: literal(b"\xff"),
        UnsupportedOperation,
        "a literal bytes value b'\\xff' cannot be encoded: the wire carries binary"
        " literals as UTF-8 text, and these bytes are not UTF-8",
    )


def dec(unscaled_high, unscaled_low, precision, scale):
    return scalar(
        kind=vocab.SCALAR_KIND_DECIMAL128,
        dec128_high=unscaled_high,
        dec128_low=unscaled_low,
        dec128_precision=precision,
        dec128_scale=scale,
    )


def test_decimal_precision_scale_and_the_two_words():
    D_ = decimal.Decimal
    # The precision counts at least one integer digit.
    assert literal(D_("0.05")) == dec(0, 5, 3, 2)
    assert literal(D_("0")) == dec(0, 0, 1, 0)
    assert literal(D_("-0.00")) == dec(0, 0, 3, 2)
    # A positive exponent is digits, not scale.
    assert literal(D_("1E+2")) == dec(0, 100, 3, 0)
    assert literal(D_(-1)) == dec(-1, -1, 1, 0)
    # The low word is the bit pattern of the low 64 bits.
    assert literal(D_(2**63)) == dec(0, -(2**63), 19, 0)
    assert literal(D_(2**63 - 1)) == dec(0, 2**63 - 1, 19, 0)
    assert literal(D_(2**64)) == dec(1, 0, 20, 0)
    assert literal(D_("9" * 38)) == dec(5421010862427522170, 687399551400673279, 38, 0)
    assert literal(D_("0." + "9" * 37)) == dec(542101086242752217, 68739955140067327, 38, 37)


def test_a_decimal_that_is_not_finite_or_too_wide_is_refused():
    for text in ("NaN", "-Infinity", "sNaN"):
        refuses(
            lambda: literal(decimal.Decimal(text)),
            UnsupportedOperation,
            f"a literal decimal {text} cannot be encoded: only a finite decimal has a decimal128 value",
        )
    for text, precision in (
        ("1" * 39, 39),
        ("0." + "1" * 38, 39),
        ("1E+38", 39),
        ("1E+999999999", 1000000000),
        ("-125E+36", 39),
    ):
        refuses(
            lambda: literal(decimal.Decimal(text)),
            UnsupportedOperation,
            f"a literal decimal {decimal.Decimal(text)} cannot be encoded: it needs a precision of {precision},"
            " and decimal128 holds at most 38 digits",
        )


def test_temporal_literals_count_from_the_epoch():
    assert literal(datetime.date(1970, 1, 1)) == scalar(kind=vocab.SCALAR_KIND_DATE32)
    assert literal(datetime.date(1969, 12, 31)) == scalar(kind=vocab.SCALAR_KIND_DATE32, date32_val=-1)
    assert literal(datetime.date(1, 1, 1)) == scalar(kind=vocab.SCALAR_KIND_DATE32, date32_val=-719162)
    assert literal(datetime.datetime(1969, 12, 31, 23, 59, 59, 999999)) == scalar(
        kind=vocab.SCALAR_KIND_TIMESTAMP, ts_micros=-1
    )
    assert literal(datetime.datetime(1970, 1, 1)) == scalar(kind=vocab.SCALAR_KIND_TIMESTAMP)
    assert literal(datetime.time(0, 0)) == scalar(kind=vocab.SCALAR_KIND_TIME)
    assert literal(datetime.time(0, 0, 0, 1)) == scalar(kind=vocab.SCALAR_KIND_TIME, int_val=1)
    assert literal(datetime.timedelta(microseconds=-1)) == scalar(
        kind=vocab.SCALAR_KIND_INTERVAL, iv_days=-1, iv_nanos=86_399_999_999_000
    )
    assert literal(datetime.timedelta(0)) == scalar(kind=vocab.SCALAR_KIND_INTERVAL)


def test_a_datetime_or_time_with_a_zone_is_refused():
    utc = datetime.timezone.utc
    refuses(
        lambda: literal(datetime.datetime(2024, 1, 1, tzinfo=utc)),
        UnsupportedOperation,
        "a literal datetime with a time zone (UTC) cannot be encoded: the wire's"
        " datetime literal has no zone; pass a naive datetime",
    )
    refuses(
        lambda: literal(datetime.time(1, tzinfo=utc)),
        UnsupportedOperation,
        "a literal time with a time zone (UTC) cannot be encoded: the wire's time"
        " literal has no zone; pass a naive time",
    )


def test_the_type_of_each_kind_of_literal():
    want = [
        (1, "INT64"),
        (2**63, "UINT64"),
        (1.5, "FLOAT64"),
        (True, "BOOL"),
        ("x", "STRING"),
        (b"x", "NULL"),
        (decimal.Decimal("1.5"), "DECIMAL128"),
        (datetime.date(2024, 1, 1), "DATE32"),
        (datetime.datetime(2024, 1, 1), "TIMESTAMP_US"),
        (datetime.time(1), "NULL"),
        (datetime.timedelta(1), "NULL"),
        (None, "INT64"),
    ]
    for value, arrow in want:
        f = expr_field(Lit(value), SCHEMA)
        assert (f.name, f.nullable) == ("literal", False), f
        assert arrow_of(Lit(value)) == arrow, (value, arrow_of(Lit(value)))
    f = expr_field(Lit(decimal.Decimal("-12.345")), SCHEMA)
    assert (f.decimal_precision, f.decimal_scale, f.dtype_code) == (5, 3, vocab._DT_INVALID), f
    assert expr_field(Lit(datetime.datetime(2024, 1, 1)), SCHEMA).dtype_code == vocab._DT_INT64


# ---- columns ----------------------------------------------------------------


def test_a_column_reference_carries_its_side():
    for side, wire in ((None, vocab.COL_SIDE_NONE), ("left", vocab.COL_SIDE_LEFT), ("right", vocab.COL_SIDE_RIGHT)):
        assert encode_expr(ColRef("a", side), SCHEMA) == pb.WireExpr(col_ref=pb.WireColRef(name="a", side=wire))


def test_a_column_field_drops_metadata_and_keeps_type_scale_zone_and_children():
    zoned = column("t", "TIMESTAMP_US", tz="UTC", flags=3, union_type_ids=[1], dict_index_type_id=2)
    schema = SCHEMA + [zoned]
    assert expr_field(A, schema) == pb.WireField(
        name="a", arrow_type_id=type_id("INT64"), dtype_code=vocab._DT_INT64, dict_index_type_id=4
    )
    assert expr_field(ColRef("t"), schema) == pb.WireField(
        name="t",
        arrow_type_id=type_id("TIMESTAMP_US"),
        dtype_code=vocab._DT_INT64,
        nullable=True,
        tz="UTC",
        dict_index_type_id=4,
    )
    assert expr_field(D, schema) == pb.WireField(
        name="d", arrow_type_id=type_id("DECIMAL128"), nullable=True, decimal_precision=12,
        decimal_scale=2, dict_index_type_id=4,
    )
    f = expr_field(Alias(ST, "renamed"), schema)
    assert (f.name, list(f.child_names), list(f.child_nullables)) == ("renamed", ["k", "v"], [False, True]), f


def test_the_first_column_of_a_name_is_the_one_read():
    schema = [column("x", "INT32"), column("x", "STRING")]
    assert arrow_of_in(ColRef("x"), schema) == "INT32"


def arrow_of_in(node, schema):
    return vocab.ArrowType.Name(expr_field(node, schema).arrow_type_id + 1).removeprefix("ARROW_TYPE_")


def test_an_unknown_column_is_refused_before_anything_is_encoded():
    deep = When(((Compare("gt", A, Lit(1)), Arith("add", B, ColRef("nope"))),), Lit(0))
    message = (
        "no column named 'nope' in this frame; the frame's columns are: a, b, i, f, d, s, st"
    )
    refuses(lambda: encode_expr(deep, SCHEMA), KeyError, message)
    refuses(lambda: expr_field(deep, SCHEMA), KeyError, message)
    refuses(
        lambda: encode_expr(ColRef("aa"), SCHEMA),
        KeyError,
        "no column named 'aa' in this frame; the closest is 'a'; the frame's columns are: a, b, i, f, d, s, st",
    )


def test_a_schema_holds_wire_fields_and_a_node_is_an_expression():
    refuses(lambda: encode_expr(A, ["a"]), TypeError, "a schema holds WireField values, not str")
    refuses(lambda: expr_field(A, [None]), TypeError, "a schema holds WireField values, not NoneType")
    refuses(lambda: encode_expr(3, SCHEMA), TypeError, "not an expression node: int")
    refuses(lambda: expr_field("a", SCHEMA), TypeError, "not an expression node: str")


def test_a_struct_field_of_something_else_or_of_a_missing_name_is_refused():
    for call in (encode_expr, expr_field):
        refuses(
            lambda: call(StructField(A, "k"), SCHEMA),
            TypeError,
            "StructField reads the field 'k' of a value of Arrow type id 5, and only a struct (id 21) has fields",
        )
        refuses(
            lambda: call(StructField(ST, "z"), SCHEMA),
            KeyError,
            "the struct has no field named 'z'; its fields are: k, v",
        )


# ---- arithmetic types -------------------------------------------------------


def test_int32_arithmetic_widens_only_for_an_int_literal_int32_cannot_hold():
    for op in ("add", "sub", "mul", "div"):
        assert arrow_of(Arith(op, I, Lit(2**31))) == "INT64", op
        assert arrow_of(Arith(op, I, Lit(-(2**31) - 1))) == "INT64", op
        assert arrow_of(Arith(op, I, Lit(2**31 - 1))) == "INT32", op
        assert arrow_of(Arith(op, I, Lit(-(2**31)))) == "INT32", op
    # Not for the remainder, a literal on the left, a uint64, a bool or a column.
    assert arrow_of(Arith("mod", I, Lit(2**31))) == "INT32"
    assert arrow_of(Arith("add", Lit(2**31), I)) == "INT64"
    assert arrow_of(Arith("add", I, Lit(2**63))) == "INT32"
    assert arrow_of(Arith("add", I, Lit(True))) == "INT32"
    assert arrow_of(Arith("add", I, B)) == "INT32"
    assert arrow_of(Arith("add", I, Lit(1.5))) == "FLOAT64"


def dec_field(node):
    f = expr_field(node, SCHEMA)
    return arrow_of(node), f.decimal_precision, f.decimal_scale


def test_decimal_arithmetic_types():
    narrow = Lit(decimal.Decimal("1.5"))  # decimal(2, 1)
    assert dec_field(Arith("sub", D, narrow)) == ("DECIMAL128", 13, 2)
    assert dec_field(Arith("mul", D, narrow)) == ("DECIMAL128", 15, 3)
    assert dec_field(Arith("mod", narrow, D)) == ("DECIMAL128", 2, 1)
    assert dec_field(Arith("add", A, D)) == ("DECIMAL128", 22, 2)
    assert dec_field(Arith("mul", A, D)) == ("DECIMAL128", 32, 2)
    assert dec_field(Arith("mod", D, A)) == ("DECIMAL128", 12, 2)
    # Against a type other than int64 or float64 the decimal side's type stays.
    assert dec_field(Arith("mul", I, D)) == ("DECIMAL128", 12, 2)
    assert dec_field(Arith("div", D, I)) == ("DECIMAL128", 12, 2)
    assert dec_field(Arith("add", F, D)) == ("FLOAT64", 0, 0)
    # The precision stops at 38; the scale of a product does not.
    wide = Lit(decimal.Decimal("0." + "1" * 30))  # decimal(31, 30)
    assert dec_field(Arith("add", D, wide)) == ("DECIMAL128", 38, 30)
    assert dec_field(Arith("mul", wide, wide)) == ("DECIMAL128", 38, 60)


def test_interval_arithmetic_and_the_left_operands_type_otherwise():
    schema = SCHEMA + [column("iv", "INTERVAL_MONTH_DAY_NANO")]
    iv = ColRef("iv")
    assert arrow_of_in(Arith("sub", iv, iv), schema) == "INTERVAL_MONTH_DAY_NANO"
    assert arrow_of_in(Arith("mul", iv, iv), schema) == "INTERVAL_MONTH_DAY_NANO"
    assert arrow_of_in(Arith("add", S, A), schema) == "STRING"
    f = expr_field(Arith("add", A, A), SCHEMA)
    assert (f.name, f.nullable) == ("expr", True), f


def test_unary_types_keep_the_operands_nullability():
    assert expr_field(Unary("abs", A), SCHEMA) == pb.WireField(
        name="abs", arrow_type_id=type_id("INT64"), dtype_code=vocab._DT_INT64, dict_index_type_id=4
    )
    assert expr_field(Unary("negate", D), SCHEMA).decimal_precision == 0


# ---- digit-count rounds -----------------------------------------------------


def test_round_digits_encodes_its_rule_its_child_and_its_digits():
    for op, member in (("round", "RDG_ROUND"), ("trunc", "RDG_TRUNC"), ("round_half_even", "RDG_ROUND_HALF_EVEN")):
        for digits in (-(2**31), -2, 0, 3, 2**31 - 1):
            got = encode_expr(RoundDigits(op, F, digits), SCHEMA)
            assert got.WhichOneof("node") == "round_digits", got
            assert got.round_digits.op == getattr(vocab, member), (op, got)
            assert got.round_digits.digits == digits, (op, digits, got)
            assert got.round_digits.child == encode_expr(F, SCHEMA)
    assert vocab.RDG_ROUND_HALF_EVEN == 3 and vocab.RDG_ROUND == 1 and vocab.RDG_TRUNC == 2


def test_round_digits_of_an_expression_encodes_the_operand_inside():
    node = RoundDigits("round_half_even", Arith("mul", F, Lit(2.0)), 1)
    got = encode_expr(node, SCHEMA)
    assert got.round_digits.child == encode_expr(Arith("mul", F, Lit(2.0)), SCHEMA)
    assert got.round_digits.digits == 1


def test_round_digits_zero_is_a_real_count():
    got = encode_expr(RoundDigits("round_half_even", F, 0), SCHEMA)
    assert got.WhichOneof("node") == "round_digits"
    assert got.round_digits.digits == 0
    assert got.round_digits.op == vocab.RDG_ROUND_HALF_EVEN


def test_round_digits_type_is_the_operands_and_its_name_is_the_engines():
    for node, name, arrow, nullable in (
        (RoundDigits("round_half_even", F, 1), "round", "FLOAT64", True),
        (RoundDigits("round", A, -1), "round", "INT64", False),
        (RoundDigits("trunc", I, 0), "trunc", "INT32", True),
    ):
        f = expr_field(node, SCHEMA)
        assert (f.name, arrow_of(node), f.nullable) == (name, arrow, nullable), (node, f)


def test_round_digits_of_a_decimal_operand_is_refused_by_name():
    refuses(
        lambda: expr_field(RoundDigits("round", D, 1), SCHEMA),
        UnsupportedOperation,
        "a digit-count round of a decimal128 operand cannot be encoded here",
    )


def test_round_digits_of_an_unknown_column_is_refused_before_encoding():
    refuses(
        lambda: encode_expr(RoundDigits("round", ColRef("nope"), 1), SCHEMA),
        KeyError,
        "no column named 'nope' in this frame; the frame's columns are: a, b, i, f, d, s, st",
    )


# ---- casts ------------------------------------------------------------------


def test_a_cast_carries_all_six_parts():
    got = encode_expr(Cast(S, None, try_cast=True, arrow="date32"), SCHEMA).cast
    assert got == pb.WireCast(
        child=pb.WireExpr(col_ref=pb.WireColRef(name="s", side=vocab.COL_SIDE_NONE)),
        target_dtype_code=vocab._DT_INT32,
        target_arrow_type_id=type_id("DATE32"),
        try_cast=True,
    )
    got = encode_expr(Cast(A, "uint8", arrow="decimal128", precision=38, scale=38), SCHEMA).cast
    assert (got.target_dtype_code, got.target_arrow_type_id, got.decimal_precision, got.decimal_scale) == (
        vocab._DT_UINT8,
        type_id("DECIMAL128"),
        38,
        38,
    )


def test_the_dtype_a_cast_to_each_arrow_type_carries():
    want = {
        "time32_ms": vocab._DT_INT32,
        "time64_ns": vocab._DT_INT64,
        "duration_s": vocab._DT_INT64,
        "date64": vocab._DT_INT64,
        "timestamp": vocab._DT_INT64,
        "bool": vocab._DT_BOOL,
        "uint16": vocab._DT_UINT16,
        "large_string": vocab._DT_INVALID,
        "list": vocab._DT_INVALID,
    }
    for arrow, code in want.items():
        assert encode_expr(Cast(A, None, arrow=arrow), SCHEMA).cast.target_dtype_code == code, arrow


def test_a_cast_field_is_the_childs_name_with_the_target_type():
    f = expr_field(Cast(A, None, arrow="decimal128", precision=9, scale=4), SCHEMA)
    assert (f.name, arrow_of(Cast(A, "float64")), f.nullable, f.decimal_precision, f.decimal_scale) == (
        "a", "FLOAT64", False, 9, 4,
    )
    assert expr_field(Cast(A, "int8", try_cast=True), SCHEMA).nullable is True
    assert expr_field(Cast(A, None, arrow="timestamp_ns"), SCHEMA).dtype_code == vocab._DT_INT64


def test_a_decimal_cast_outside_decimal128_is_refused():
    for precision, scale in ((39, 0), (5, 6)):
        refuses(
            lambda: encode_expr(Cast(A, None, arrow="decimal128", precision=precision, scale=scale), SCHEMA),
            UnsupportedOperation,
            f"a cast to decimal128({precision}, {scale}) cannot be encoded: decimal128 takes"
            " a precision of 1 to 38 and a scale of at most the precision",
        )


# ---- CASE -------------------------------------------------------------------


P = Compare("gt", A, Lit(0))


def results(node):
    w = encode_expr(node, SCHEMA).when
    return [c.result for c in w.cases] + [w.default_expr]


def test_a_float_case_makes_its_int_and_null_literals_float():
    got = results(When(((P, Lit(1)), (P, Lit(None)), (P, Lit(True)), (P, Lit("x"))), F))
    assert [r.literal for r in got[:4]] == [
        scalar(dtype_code=vocab._DT_FLOAT64, float_val=1.0),
        scalar(null_dtype_code=vocab._DT_FLOAT64),
        scalar(dtype_code=vocab._DT_BOOL, bool_val=True),
        scalar(kind=vocab.SCALAR_KIND_STRING, string_val="x"),
    ]
    assert arrow_of(When(((P, Lit(None)),), F)) == "FLOAT64"
    # Conditions are not results, and a literal under an operator is not one.
    w = encode_expr(When(((Compare("eq", A, Lit(1)), Arith("add", A, Lit(1))),), F), SCHEMA).when
    assert w.cases[0].condition.binary_op.right.literal.dtype_code == vocab._DT_INT64
    assert w.cases[0].result.binary_op.right.literal.dtype_code == vocab._DT_INT64


def test_a_case_without_a_float_result_keeps_its_literals():
    got = results(When(((P, Lit(1)),), Lit(None)))
    assert [r.literal for r in got] == [scalar(dtype_code=vocab._DT_INT64, int_val=1), scalar(null_dtype_code=vocab._DT_INT64)]
    assert arrow_of(When(((P, Lit(None)),), A)) == "INT64"
    assert arrow_of(When(((P, A),), Lit(2.5))) == "INT64"


def test_a_deeply_nested_case_types_and_encodes():
    node = Lit(1)
    for _ in range(60):
        node = When(((P, node),), Lit(None))
    assert arrow_of(node) == "INT64"
    assert encode_expr(node, SCHEMA).when.default_expr.literal == scalar(null_dtype_code=vocab._DT_INT64)


def test_an_int_too_wide_for_int64_and_uint64_is_refused_in_a_float_case_too():
    refuses(
        lambda: encode_expr(When(((P, Lit(2**64)),), F), SCHEMA),
        UnsupportedOperation,
        "a literal integer 18446744073709551616 cannot be encoded: it is outside int64 and uint64;"
        " pass it as a decimal.Decimal or a float",
    )


# ---- string functions of several arguments ----------------------------------


def test_string_functions_take_their_argument_counts():
    two = (S, Lit("a"))
    assert len(encode_expr(StringFnN("concat", (S,)), SCHEMA).string_fn_n.args) == 1
    assert len(encode_expr(StringFnN("concat_ws", two + (S, S)), SCHEMA).string_fn_n.args) == 4
    refuses(
        lambda: encode_expr(StringFnN("lpad", two), SCHEMA),
        ValueError,
        "StringFnN lpad takes 3 arguments, not 2",
    )
    refuses(
        lambda: encode_expr(StringFnN("strpos", two + (S,)), SCHEMA),
        ValueError,
        "StringFnN strpos takes 2 arguments, not 3",
    )
    refuses(
        lambda: encode_expr(StringFnN("concat_ws", (S,)), SCHEMA),
        ValueError,
        "StringFnN concat_ws takes at least 2 arguments, not 1",
    )


# ---- names and nullability --------------------------------------------------


def test_the_name_and_nullability_of_each_kind_of_result():
    want = [
        (Compare("eq", A, A), "expr", "BOOL", True),
        (BoolOp("and", P, P), "expr", "BOOL", True),
        (Unary("not", P), "not", "BOOL", True),
        (Unary("is_null", A), "is_null", "BOOL", False),
        (Unary("is_not_null", B), "is_not_null", "BOOL", False),
        (Unary("sign", F), "sign", "INT8", True),
        (Unary("bit_count", B), "bit_count", "INT8", True),
        (Unary("negate", A), "neg", "INT64", False),
        (Unary("trunc", F), "trunc", "FLOAT64", True),
        (Extract("year", A), "extract", "INT64", True),
        (Extract("trunc_day", A), "date_trunc", "INT64", False),
        (StructField(ST, "k"), "k", "INT64", False),
        (When(((P, S),), S), "case", "STRING", True),
    ]
    for node, name, arrow, nullable in want:
        f = expr_field(node, SCHEMA)
        assert (f.name, arrow_of(node), f.nullable) == (name, arrow, nullable), (node, f)


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("plan_expr: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
