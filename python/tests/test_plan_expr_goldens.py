"""The expression encoder against plans the engine built: for each `expr_*`
golden of plan_wire, a projection over a scan that
src/plan_wire/tests/test_plan_wire_expr_goldens*.mojo builds with the engine's
own expression factories, the expressions here, encoded by komira._plan over
the scan's columns, together with the output schema `expr_field` derives,
encode to exactly the golden's `<stem>.canonical.hex`: protoc's encoding of the
engine's plan, which plan_wire's test decodes back to the plan the engine
built.

    test_plan_expr_goldens.py --golden <dir>

`--golden` is the directory of plan_wire's goldens. The scan under each
projection is taken from the golden as it is: scans are the relational
encoder's.
"""

import argparse
import datetime
import decimal
import os
import sys

from komira._ops import (
    Alias,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Extract,
    Lit,
    MathFn,
    MathFn2,
    Regexp,
    StringFn,
    StringFnN,
    StringOp,
    StructField,
    Substring,
    Unary,
    When,
    _vocab,
)
from komira._plan import encode_expr, expr_field
from komira.plan.v1 import plan_pb2

A, B, I, F, D, S = (ColRef(n) for n in ("a", "b", "i", "f", "d", "s"))
DT, TS, IV, ST = (ColRef(n) for n in ("dt", "ts", "iv", "st"))


def gt(x, v):
    return Compare("gt", x, Lit(v))


# Every kind of literal the engine can project, each under its own name. A
# uint64, binary, time-of-day or interval literal is not here: plan_wire's
# reader refuses to project one (the engine has no way to materialize it), so
# test_plan_expr.py holds their encoding instead.
LITERALS = [
    Alias(Lit(42), "l_int"),
    Alias(Lit(-7), "l_neg"),
    Alias(Lit(2.5), "l_float"),
    Alias(Lit(True), "l_true"),
    Alias(Lit(False), "l_false"),
    Alias(Lit("text"), "l_str"),
    Alias(Lit(""), "l_empty"),
    Alias(Lit(decimal.Decimal("-1234.50")), "l_dec"),
    Alias(Lit(decimal.Decimal("12345678901234567890.5")), "l_bigdec"),
    Alias(Lit(datetime.date(2024, 2, 29)), "l_date"),
    Alias(Lit(datetime.datetime(2024, 2, 29, 12, 30, 15, 250)), "l_ts"),
    Alias(Lit(None), "l_null"),
]

# Comparisons, arithmetic (with the engine's float, int32-widening, decimal and
# interval result types), the boolean operators and every unary operator; and
# three bare column references, whose fields carry the column's zone and
# children but not its metadata.
OPERATORS = [
    Alias(Compare("eq", A, B), "cmp_eq"),
    Alias(Compare("ne", A, Lit(1)), "cmp_ne"),
    Alias(Compare("lt", F, Lit(0.5)), "cmp_lt"),
    Alias(Compare("le", S, Lit("m")), "cmp_le"),
    Alias(Compare("gt", D, Lit(decimal.Decimal("9.99"))), "cmp_gt"),
    Alias(Compare("ge", DT, Lit(datetime.date(2024, 2, 29))), "cmp_ge"),
    Alias(Arith("add", A, B), "ar_add"),
    Alias(Arith("sub", F, A), "ar_sub"),
    Alias(Arith("mul", I, Lit(3_000_000_000)), "ar_mul"),
    Alias(Arith("div", I, Lit(2)), "ar_div"),
    Alias(Arith("mod", A, Lit(7)), "ar_mod"),
    Alias(Arith("add", D, D), "dec_add"),
    Alias(Arith("mul", D, A), "dec_mul"),
    Alias(Arith("div", D, Lit(2.0)), "dec_div"),
    Alias(Arith("mod", D, D), "dec_mod"),
    Alias(Arith("sub", D, A), "dec_sub_int"),
    Alias(Arith("div", A, D), "dec_div_int"),
    Alias(Arith("add", IV, IV), "iv_add"),
    Alias(BoolOp("and", gt(A, 1), Unary("is_null", B)), "bool_and"),
    Alias(BoolOp("or", Compare("lt", A, Lit(0)), Lit(True)), "bool_or"),
    Alias(Unary("not", gt(A, 1)), "un_not"),
    Alias(Unary("negate", A), "un_neg"),
    Alias(Unary("is_null", B), "un_is_null"),
    Alias(Unary("is_not_null", B), "un_is_not_null"),
    Alias(Unary("abs", F), "un_abs"),
    Alias(Unary("sign", I), "un_sign"),
    Alias(Unary("trunc", F), "un_trunc"),
    Alias(Unary("round", D), "un_round"),
    Alias(Unary("bit_count", A), "un_bit_count"),
    A,
    TS,
    ST,
]

# Casts to a primitive type, to an Arrow type, to a decimal, with try, and to
# both; CASE over int, float, NULL, string, decimal and bool results, and a
# CASE inside a CASE.
CASTS_AND_CASES = [
    Alias(Cast(A, "float64"), "c_f64"),
    Alias(Cast(F, "int32"), "c_i32"),
    Alias(Cast(I, "float16"), "c_f16"),
    Alias(Cast(S, "int64", try_cast=True), "c_try"),
    Alias(Cast(S, None, arrow="date32"), "c_date"),
    Alias(Cast(A, None, arrow="timestamp_us"), "c_ts"),
    Alias(Cast(A, None, arrow="string"), "c_str"),
    Alias(Cast(F, None, arrow="decimal128", precision=10, scale=3), "c_dec"),
    Alias(Cast(A, None, try_cast=True, arrow="decimal128", precision=18), "c_try_dec"),
    Alias(Cast(A, "int64", arrow="timestamp_ms"), "c_both"),
    Alias(When(((gt(A, 0), Lit(1)), (Compare("lt", B, Lit(0)), Lit(2))), Lit(-1)), "w_int"),
    Alias(When(((gt(A, 0), Lit(1)),), Lit(2.5)), "w_promote"),
    Alias(When(((Unary("is_null", B), Lit(None)),), F), "w_null_float"),
    Alias(When(((Unary("is_null", B), Lit(None)),), A), "w_null_int"),
    Alias(When(((StringOp("starts_with", S, "x"), S),), Lit("none")), "w_str"),
    Alias(When(((gt(A, 0), D),), D), "w_dec"),
    Alias(When(((gt(A, 0), Lit(True)),), Lit(1.5)), "w_bool_float"),
    Alias(
        When(((gt(A, 0), When(((Compare("lt", B, Lit(0)), Lit(1)),), Lit(2.0))),), Lit(3)),
        "w_nested",
    ),
]

_STRING_FN_N_ARGS = {
    "concat": (S, Lit("-"), S),
    "concat_ws": (Lit(","), S, S),
    "replace": (S, Lit("a"), Lit("b")),
    "lpad": (S, Lit(5), Lit("*")),
    "rpad": (S, Lit(5), Lit("*")),
    "repeat": (S, Lit(3)),
    "strpos": (S, Lit("a")),
    "levenshtein": (S, Lit("abc")),
    "damerau_levenshtein": (S, Lit("abc")),
    "hamming": (S, Lit("abc")),
    "translate": (S, Lit("ab"), Lit("xy")),
    "jaro": (S, Lit("abc")),
    "jaro_winkler": (S, Lit("abc")),
    "jaccard": (S, Lit("abc")),
    "trim": (S, Lit("abc")),
    "ltrim": (S, Lit("abc")),
    "rtrim": (S, Lit("abc")),
}

_REGEXPS = [
    Regexp("like", S, "^a.*"),
    Regexp("match", S, "(a)(b)", flags="i"),
    Regexp("replace", S, "a+", replacement="X", flags="g"),
    Regexp("extract", S, "(a)(b)", group=1),
    Regexp("split_to_array", S, ","),
    Regexp("extract_all", S, "(a)(b)", group=2),
    Regexp("count", S, "a"),
    Regexp("instr", S, "b"),
    Regexp("substr", S, "a(b)", group=1),
    Regexp("full_match", S, "a.*b", flags="i"),
]

# Every string operator, regexp op, one-argument and many-argument string
# function, and substrings with a length, without one, and of length zero.
STRINGS = (
    [Alias(StringOp(op, S, "ab"), "so_" + op) for op in ("contains", "starts_with", "ends_with")]
    + [Alias(r, "rx_" + r.op) for r in _REGEXPS]
    + [Alias(StringFn(op, S), "sf_" + op) for op in sorted(_vocab.STRING_FNS)]
    + [Alias(StringFnN(op, args), "sn_" + op) for op, args in sorted(_STRING_FN_N_ARGS.items())]
    + [
        Alias(Substring(S, 2, 4), "sub_len"),
        Alias(Substring(S, -3), "sub_open"),
        Alias(Substring(S, 1, 0), "sub_zero"),
    ]
)

_TRUNC_ON_DATE = ("trunc_year", "trunc_quarter", "trunc_month", "trunc_week", "trunc_day")

# Every math function of one and two operands, every extract unit (truncations
# of the date and of the zoned timestamp), and both fields of the struct.
MATH_AND_TEMPORAL = (
    [Alias(MathFn(op, F), "m_" + op) for op in sorted(_vocab.MATH_FNS)]
    + [Alias(MathFn2("atan2", F, A), "m2_atan2"), Alias(MathFn2("pow", A, Lit(2)), "m2_pow")]
    + [
        Alias(Extract(unit, DT if unit in _TRUNC_ON_DATE else TS), "ex_" + unit)
        for unit in sorted(_vocab.EXTRACT_UNITS)
    ]
    + [Alias(StructField(ST, "k"), "st_k"), Alias(StructField(ST, "v"), "st_v")]
)

GOLDENS = {
    "expr_literals": LITERALS,
    "expr_operators": OPERATORS,
    "expr_cast_when": CASTS_AND_CASES,
    "expr_strings": STRINGS,
    "expr_math_temporal": MATH_AND_TEMPORAL,
}


def read_hex(path):
    with open(path, encoding="ascii") as f:
        return bytes.fromhex(f.read())


def encoded(golden, exprs):
    """The golden's plan with its projection's expressions and output schema
    made by the encoder, over the scan the golden holds."""
    plan = plan_pb2.WirePlanEnvelope.FromString(golden).plan
    assert plan.WhichOneof("node") == "project", f"the golden's plan is a {plan.WhichOneof('node')}"
    child = plan.project.child
    columns = list(child.output_schema.fields)
    envelope = plan_pb2.WirePlanEnvelope(format_version=4)
    envelope.plan.output_schema.fields.extend(expr_field(e, columns) for e in exprs)
    envelope.plan.project.exprs.extend(encode_expr(e, columns) for e in exprs)
    envelope.plan.project.child.CopyFrom(child)
    return envelope


def check_golden(directory, stem, exprs):
    golden = read_hex(os.path.join(directory, stem + ".canonical.hex"))
    want = plan_pb2.WirePlanEnvelope.FromString(golden)
    got = encoded(golden, exprs)
    want_fields, got_fields = want.plan.output_schema.fields, got.plan.output_schema.fields
    assert len(got_fields) == len(want_fields), (
        f"{stem}: {len(got_fields)} output fields, the engine's plan has {len(want_fields)}"
    )
    for i, (g, w) in enumerate(zip(got_fields, want_fields)):
        assert g == w, f"{stem}: output field {i} is\n{g}\nand the engine derives\n{w}"
    for i, (g, w) in enumerate(zip(got.plan.project.exprs, want.plan.project.exprs)):
        assert g == w, f"{stem}: expression {i} ({exprs[i]}) encodes to\n{g}\nand the engine's is\n{w}"
    assert got == want, f"{stem}: the envelopes differ outside the expressions and the schema"
    data = got.SerializeToString(deterministic=True)
    assert data == golden, f"{stem}: {len(data)} bytes that are not the golden's {len(golden)}"


def test_every_expression_golden_is_checked(directory):
    """Every `expr_*` golden of the directory has its expressions here, and
    every expression list here has its golden."""
    suffix = ".canonical.hex"
    stems = {n[: -len(suffix)] for n in os.listdir(directory) if n.startswith("expr_") and n.endswith(suffix)}
    assert stems == set(GOLDENS), f"goldens without expressions here or the reverse: {sorted(stems ^ set(GOLDENS))}"


def test_each_golden_encodes_to_the_engines_bytes(directory):
    for stem, exprs in GOLDENS.items():
        check_golden(directory, stem, exprs)


def test_the_check_fails_on_a_different_expression(directory):
    """A projection that differs from the engine's in one operand fails the
    check, naming the expression."""
    exprs = list(OPERATORS)
    exprs[0] = Alias(Compare("eq", B, A), "cmp_eq")
    try:
        check_golden(directory, "expr_operators", exprs)
    except AssertionError as e:
        message = str(e)
    else:
        raise AssertionError("a swapped comparison passed the check")
    assert message.startswith("expr_operators: expression 0 ("), message


def test_the_check_fails_on_a_different_field(directory):
    """A projection whose expressions type differently fails on the field."""
    exprs = list(OPERATORS)
    exprs[6] = Alias(Arith("add", F, B), "ar_add")
    try:
        check_golden(directory, "expr_operators", exprs)
    except AssertionError as e:
        message = str(e)
    else:
        raise AssertionError("a float sum in place of an int sum passed the check")
    assert message.startswith("expr_operators: output field 6 is\n"), message


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden", required=True)
    directory = parser.parse_args(argv).golden
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f(directory)
    print("plan_expr_goldens: {} tests".format(len(tests)))


if __name__ == "__main__":
    main(sys.argv[1:])
    sys.exit(0)
