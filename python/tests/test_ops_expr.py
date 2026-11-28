"""The expression nodes of komira._ops: construction, structural equality and
hashing, every refusal (exact class and full message), is_predicate per class,
and the helper constructors and_all, or_all, is_in, between, as_node and
output_name.

    test_ops_expr.py
"""

import dataclasses
import datetime
import decimal
import sys

import komira
from komira import KomiraError
from komira._errors import UnsupportedOperation
from komira._ops import (
    EXPR_NODES,
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
    RoundDigits,
    StringFn,
    StringFnN,
    StringOp,
    StructField,
    Substring,
    Unary,
    When,
    _vocab,
    and_all,
    as_node,
    between,
    is_in,
    is_predicate,
    or_all,
    output_name,
)

A = ColRef("a")
B = ColRef("b")
C = ColRef("c")
P = Compare("eq", A, Lit(1))
Q = Compare("gt", B, Lit(2))


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def one_of(vocab):
    return ", ".join(sorted(vocab))


def test_every_node_class_is_listed():
    names = [c.__name__ for c in EXPR_NODES]
    assert names == [
        "ColRef", "Lit", "Compare", "Arith", "BoolOp", "Unary", "RoundDigits", "Cast", "When", "StringOp",
        "Regexp", "StringFn", "StringFnN", "Substring", "MathFn", "MathFn2", "Extract",
        "StructField", "Alias", "UdfCall",
    ], names


def test_unsupported_operation_is_a_public_komira_error():
    assert issubclass(UnsupportedOperation, KomiraError)
    assert "UnsupportedOperation" in komira.__all__
    assert komira.UnsupportedOperation is UnsupportedOperation


def test_nodes_are_frozen_and_have_no_instance_dict():
    for node in (A, Lit(1), P, Alias(A, "x")):
        first = dataclasses.fields(node)[0].name
        e = raised(lambda: setattr(node, first, "z"))
        assert isinstance(e, dataclasses.FrozenInstanceError), repr(e)
        assert not hasattr(node, "__dict__")


def test_structural_equality_and_hash_of_equal_trees():
    def build():
        return Alias(
            When(((Compare("lt", ColRef("x", "left"), Lit(1.5)),
                   Arith("add", ColRef("y"), Lit("s"))),),
                 Lit(None)),
            "out",
        )

    assert build() == build() and hash(build()) == hash(build())
    assert len({build(), build()}) == 1


def test_structural_inequality_of_each_field():
    assert ColRef("a") != ColRef("b")
    assert ColRef("a") != ColRef("a", "left")
    assert ColRef("a", "left") != ColRef("a", "right")
    assert Compare("eq", A, B) != Compare("ne", A, B)
    assert Compare("eq", A, B) != Compare("eq", B, A)
    assert Compare("eq", A, B) != Arith("add", A, B)
    assert Cast(A, "int32") != Cast(A, "int32", True)
    assert Substring(A, 1) != Substring(A, 1, 2)
    assert Alias(A, "x") != Alias(A, "y")
    assert When(((P, A),), B) != When(((P, A),), C)
    assert When(((P, A), (Q, B)), C) != When(((Q, B), (P, A)), C)


def test_a_node_is_not_equal_to_a_non_node():
    assert A != "a" and Lit(1) != 1 and Lit(None) != None  # noqa: E711
    assert not (A == ("a", None))


def test_colref_construction_and_sides():
    assert ColRef("a").side is None
    assert ColRef("a", "left").side == "left"
    assert ColRef("a", "right").side == "right"
    assert ColRef("a", side="left") == ColRef("a", "left")


def test_colref_refusals():
    refuses(lambda: ColRef(3), TypeError, "ColRef.name must be a str, not int")
    refuses(lambda: ColRef(None), TypeError, "ColRef.name must be a str, not NoneType")
    refuses(lambda: ColRef(""), ValueError, "ColRef.name must not be empty")
    refuses(lambda: ColRef("a", "middle"), ValueError,
            "ColRef side 'middle' is not one of: left, right")
    refuses(lambda: ColRef("a", ""), ValueError, "ColRef side '' is not one of: left, right")


def test_lit_holds_each_scalar_type():
    values = [
        None, True, False, 0, -7, 2**70, 1.5, float("inf"), "", "text", b"\x00", b"",
        decimal.Decimal("1.25"), datetime.date(2001, 2, 3),
        datetime.datetime(2001, 2, 3, 4, 5, 6), datetime.time(4, 5, 6),
        datetime.timedelta(days=1),
    ]
    for v in values:
        assert Lit(v).value is v
        assert Lit(v) == Lit(v) and hash(Lit(v)) == hash(Lit(v))


def test_lit_refusals_name_the_python_type():
    refuses(lambda: Lit([1]), TypeError, "Lit cannot hold a list")
    refuses(lambda: Lit((1,)), TypeError, "Lit cannot hold a tuple")
    refuses(lambda: Lit({}), TypeError, "Lit cannot hold a dict")
    refuses(lambda: Lit(object()), TypeError, "Lit cannot hold a object")
    refuses(lambda: Lit(A), TypeError, "Lit cannot hold a ColRef")
    refuses(lambda: Lit(1 + 2j), TypeError, "Lit cannot hold a complex")


def test_lit_tells_bool_int_and_float_apart():
    assert Lit(1) != Lit(True)
    assert Lit(0) != Lit(False)
    assert Lit(1) != Lit(1.0)
    assert Lit(1.0) != Lit(True)
    assert Lit(1) != Lit(decimal.Decimal(1))
    assert Lit(1) == Lit(1) and Lit(True) == Lit(True) and Lit(1.0) == Lit(1.0)
    assert len({Lit(1), Lit(True), Lit(1.0)}) == 3
    assert Compare("eq", A, Lit(1)) != Compare("eq", A, Lit(True))


def test_lit_tells_date_and_datetime_apart():
    day = datetime.date(2001, 2, 3)
    stamp = datetime.datetime(2001, 2, 3)
    assert Lit(day) != Lit(stamp)
    assert Lit(day) == Lit(datetime.date(2001, 2, 3))


def test_lit_nan_equals_nan_and_hashes_alike():
    nan = float("nan")
    assert Lit(nan) == Lit(float("nan"))
    assert hash(Lit(nan)) == hash(Lit(float("nan")))
    assert Lit(nan) != Lit(1.0)
    assert Lit(nan) != Lit(None)
    assert Lit(decimal.Decimal("NaN")) == Lit(decimal.Decimal("NaN"))
    assert Compare("eq", A, Lit(nan)) == Compare("eq", A, Lit(float("nan")))


def test_lit_none_and_strings_and_bytes():
    assert Lit(None) == Lit(None)
    assert Lit(None) != Lit(False)
    assert Lit("1") != Lit(1)
    assert Lit(b"a") != Lit("a")


def test_compare_arith_and_bool_ops_accept_every_vocabulary_member():
    for op in _vocab.COMPARE_OPS:
        assert Compare(op, A, B).op == op
    for op in _vocab.ARITH_OPS:
        assert Arith(op, A, B).op == op
    for op in _vocab.BOOL_OPS:
        assert BoolOp(op, P, Q).op == op


def test_compare_arith_and_bool_ops_refuse_an_op_outside_the_vocabulary():
    refuses(lambda: Compare("equals", A, B), ValueError,
            "Compare op 'equals' is not one of: eq, ge, gt, le, lt, ne")
    refuses(lambda: Arith("pow", A, B), ValueError,
            "Arith op 'pow' is not one of: add, div, mod, mul, sub")
    refuses(lambda: BoolOp("xor", P, Q), ValueError, "BoolOp op 'xor' is not one of: and, or")
    refuses(lambda: Compare("EQ", A, B), ValueError,
            "Compare op 'EQ' is not one of: eq, ge, gt, le, lt, ne")


def test_an_op_that_is_not_a_str_is_a_type_error():
    refuses(lambda: Compare(1, A, B), TypeError, "Compare op must be a str, not int")
    refuses(lambda: Arith(None, A, B), TypeError, "Arith op must be a str, not NoneType")
    refuses(lambda: Unary(b"not", P), TypeError, "Unary op must be a str, not bytes")


def test_binary_nodes_refuse_a_child_that_is_not_a_node():
    refuses(lambda: Compare("eq", "a", B), TypeError,
            "Compare.left must be an expression node, not str")
    refuses(lambda: Compare("eq", A, 1), TypeError,
            "Compare.right must be an expression node, not int")
    refuses(lambda: Arith("add", None, B), TypeError,
            "Arith.left must be an expression node, not NoneType")
    refuses(lambda: Arith("add", A, [B]), TypeError,
            "Arith.right must be an expression node, not list")
    refuses(lambda: MathFn2("pow", A, 2), TypeError,
            "MathFn2.right must be an expression node, not int")
    refuses(lambda: BoolOp("and", 1, Q), TypeError,
            "BoolOp.left must be an expression node, not int")


def test_bool_op_needs_predicate_operands():
    refuses(lambda: BoolOp("and", A, Q), TypeError,
            "BoolOp and needs predicates, and its left operand is a ColRef")
    refuses(lambda: BoolOp("or", P, Arith("add", A, B)), TypeError,
            "BoolOp or needs predicates, and its right operand is a Arith")
    refuses(lambda: BoolOp("and", Lit(1), P), TypeError,
            "BoolOp and needs predicates, and its left operand is a Lit")


def test_bool_op_accepts_boolean_and_null_literals_and_aliased_predicates():
    assert BoolOp("and", Lit(True), Lit(False)).left == Lit(True)
    assert BoolOp("or", Lit(None), Alias(P, "p")).right == Alias(P, "p")


def test_unary_accepts_every_vocabulary_member():
    for op in _vocab.UNARY_OPS:
        assert Unary(op, P).op == op
        assert Unary(op, P).child is P


def test_unary_refusals():
    refuses(lambda: Unary("inverse", A), ValueError,
            "Unary op 'inverse' is not one of: " + one_of(_vocab.UNARY_OPS))
    refuses(lambda: Unary("abs", 5), TypeError, "Unary.child must be an expression node, not int")
    refuses(lambda: Unary("not", A), TypeError, "Unary not needs a predicate, not a ColRef")
    refuses(lambda: Unary("not", Lit(3)), TypeError, "Unary not needs a predicate, not a Lit")
    assert Unary("negate", A).child is A
    assert Unary("is_null", A).child is A
    assert Unary("not", Lit(True)).child == Lit(True)


def test_round_digits_accepts_every_rule_and_the_int32_range():
    for op in _vocab.ROUND_DIGITS_OPS:
        node = RoundDigits(op, A, 2)
        assert (node.op, node.child, node.digits) == (op, A, 2)
    assert _vocab.ROUND_DIGITS_OPS == {"round", "trunc", "round_half_even"}
    for digits in (-(2**31), -1, 0, 2**31 - 1):
        assert RoundDigits("round", A, digits).digits == digits
    assert RoundDigits("round", A, 1) == RoundDigits("round", A, 1)
    assert RoundDigits("round", A, 1) != RoundDigits("round", A, 2)
    assert RoundDigits("round", A, 1) != RoundDigits("trunc", A, 1)
    assert RoundDigits("round", A, 1) != Unary("round", A)


def test_round_digits_refusals():
    refuses(lambda: RoundDigits("floor", A, 1), ValueError,
            "RoundDigits op 'floor' is not one of: " + one_of(_vocab.ROUND_DIGITS_OPS))
    refuses(lambda: RoundDigits(b"round", A, 1), TypeError, "RoundDigits op must be a str, not bytes")
    refuses(lambda: RoundDigits("round", 5, 1), TypeError, "RoundDigits.child must be an expression node, not int")
    refuses(lambda: RoundDigits("round", A, 1.0), TypeError, "RoundDigits.digits must be an int, not float")
    refuses(lambda: RoundDigits("round", A, True), TypeError, "RoundDigits.digits must be an int, not bool")
    refuses(lambda: RoundDigits("round", A, None), TypeError, "RoundDigits.digits must be an int, not NoneType")
    refuses(lambda: RoundDigits("round", A, 2**31), ValueError,
            "RoundDigits.digits must be within int32, not 2147483648")
    refuses(lambda: RoundDigits("round", A, -(2**31) - 1), ValueError,
            "RoundDigits.digits must be within int32, not -2147483649")


def test_cast_construction_and_try_cast():
    for target in _vocab.CAST_TARGETS:
        assert Cast(A, target).target == target
    assert Cast(A, "int64").try_cast is False
    assert Cast(A, "int64", True).try_cast is True
    assert Cast(A, "float64", try_cast=True) == Cast(A, "float64", True)


def test_cast_to_an_arrow_type_and_a_decimal():
    assert Cast(A, "int32").arrow is None
    assert Cast(A, "int32").precision == 0 and Cast(A, "int32").scale == 0
    for arrow in _vocab.ARROW_TYPES:
        if arrow != "decimal128":
            assert Cast(A, None, arrow=arrow).arrow == arrow, arrow
    assert Cast(A, "int32", arrow="date32").target == "int32"
    dec = Cast(A, None, arrow="decimal128", precision=10, scale=2)
    assert (dec.target, dec.arrow, dec.precision, dec.scale) == (None, "decimal128", 10, 2)
    assert Cast(A, None, True, "string") == Cast(A, None, try_cast=True, arrow="string")
    assert Cast(A, None, arrow="string") != Cast(A, None, arrow="large_string")
    assert Cast(A, None, arrow="decimal128", precision=10) != dec
    assert hash(dec) == hash(Cast(A, None, arrow="decimal128", precision=10, scale=2))


def test_cast_arrow_refusals():
    refuses(lambda: Cast(A, None), ValueError, "Cast needs a target or an arrow type")
    refuses(lambda: Cast(A, None, arrow="varchar"), ValueError,
            "Cast arrow op 'varchar' is not one of: " + one_of(_vocab.ARROW_TYPES))
    refuses(lambda: Cast(A, None, arrow=3), TypeError, "Cast arrow op must be a str, not int")
    refuses(lambda: Cast(A, "string", arrow="string"), ValueError,
            "Cast op 'string' is not one of: " + one_of(_vocab.CAST_TARGETS))
    refuses(lambda: Cast(A, None, arrow="decimal128"), ValueError,
            "Cast to decimal128 needs a precision of at least 1")
    refuses(lambda: Cast(A, None, arrow="date32", precision=5), ValueError,
            "Cast precision and scale are for a decimal128 arrow type only")
    refuses(lambda: Cast(A, "int32", scale=2), ValueError,
            "Cast precision and scale are for a decimal128 arrow type only")
    refuses(lambda: Cast(A, None, arrow="decimal128", precision=-1), ValueError,
            "Cast.precision must be at least 0, not -1")
    refuses(lambda: Cast(A, None, arrow="decimal128", precision=5, scale=-1), ValueError,
            "Cast.scale must be at least 0, not -1")
    refuses(lambda: Cast(A, None, arrow="decimal128", precision=True), TypeError,
            "Cast.precision must be an int, not bool")
    refuses(lambda: Cast(A, None, arrow="decimal128", precision=5, scale=1.0), TypeError,
            "Cast.scale must be an int, not float")


def test_cast_refusals():
    refuses(lambda: Cast(A, "string"), ValueError,
            "Cast op 'string' is not one of: bool, float16, float32, float64, int16, int32, "
            "int64, int8, uint16, uint32, uint64, uint8")
    refuses(lambda: Cast(A, 5), TypeError, "Cast op must be a str, not int")
    refuses(lambda: Cast("a", "int8"), TypeError, "Cast.child must be an expression node, not str")
    refuses(lambda: Cast(A, "int8", 1), TypeError, "Cast.try_cast must be a bool, not int")
    refuses(lambda: Cast(A, "int8", None), TypeError, "Cast.try_cast must be a bool, not NoneType")


def test_when_construction_keeps_case_order():
    w = When(((P, A), (Q, B)), C)
    assert w.cases == ((P, A), (Q, B)) and w.default is C
    assert When(((P, A), (Q, B)), C) != When(((Q, B), (P, A)), C)
    assert hash(w) == hash(When(((P, A), (Q, B)), C))


def test_when_refusals():
    refuses(lambda: When((), A), ValueError, "When needs at least one (condition, result) case")
    refuses(lambda: When([(P, A)], B), TypeError, "When.cases must be a tuple, not list")
    refuses(lambda: When((P,), B), TypeError, "When case 0 must be a (condition, result) tuple")
    refuses(lambda: When(((P, A), [Q, B]), C), TypeError,
            "When case 1 must be a (condition, result) tuple")
    refuses(lambda: When(((P, A, B),), C), TypeError,
            "When case 0 must be a (condition, result) tuple")
    refuses(lambda: When(((A, B),), C), TypeError,
            "When case 0: the condition is a ColRef, not a predicate")
    refuses(lambda: When(((P, A), (Lit(1), B)), C), TypeError,
            "When case 1: the condition is a Lit, not a predicate")
    refuses(lambda: When(((P, 1),), C), TypeError,
            "When.cases[0] result must be an expression node, not int")
    refuses(lambda: When(((P, A),), "x"), TypeError,
            "When.default must be an expression node, not str")


def test_string_op_construction_and_refusals():
    for op in _vocab.STRING_OPS:
        assert StringOp(op, A, "x").op == op
    assert StringOp("contains", A, "").pattern == ""
    refuses(lambda: StringOp("like", A, "x"), ValueError,
            "StringOp op 'like' is not one of: contains, ends_with, starts_with")
    refuses(lambda: StringOp("contains", A, 3), TypeError,
            "StringOp.pattern must be a str, not int")
    refuses(lambda: StringOp("contains", A, Lit("x")), TypeError,
            "StringOp.pattern must be a str, not Lit")
    refuses(lambda: StringOp("contains", "a", "x"), TypeError,
            "StringOp.child must be an expression node, not str")


def test_regexp_construction_for_every_op():
    for op in _vocab.REGEXP_OPS:
        r = Regexp(op, A, "p")
        assert (r.replacement, r.flags, r.group) == ("", "", 0)
    assert Regexp("replace", A, "p", "r", "g").replacement == "r"
    assert Regexp("replace", A, "p", flags="gi").flags == "gi"
    for op in ("extract", "extract_all", "substr"):
        assert Regexp(op, A, "(p)", group=2).group == 2
    assert Regexp("replace", A, "p", "").replacement == ""


def test_regexp_refusals():
    refuses(lambda: Regexp("search", A, "p"), ValueError,
            "Regexp op 'search' is not one of: " + one_of(_vocab.REGEXP_OPS))
    refuses(lambda: Regexp("match", A, 1), TypeError, "Regexp.pattern must be a str, not int")
    refuses(lambda: Regexp("replace", A, "p", 1), TypeError,
            "Regexp.replacement must be a str, not int")
    refuses(lambda: Regexp("match", A, "p", flags=None), TypeError,
            "Regexp.flags must be a str, not NoneType")
    refuses(lambda: Regexp("match", A, "p", "r"), ValueError,
            "Regexp op 'match' does not take a replacement")
    refuses(lambda: Regexp("match", A, "p", group=1), ValueError,
            "Regexp op 'match' does not take a group")
    refuses(lambda: Regexp("replace", A, "p", "r", group=1), ValueError,
            "Regexp op 'replace' does not take a group")
    refuses(lambda: Regexp("extract", A, "p", group=-1), ValueError,
            "Regexp.group must be at least 0, not -1")
    refuses(lambda: Regexp("extract", A, "p", group=True), TypeError,
            "Regexp.group must be an int, not bool")
    refuses(lambda: Regexp("extract", A, "p", group=1.0), TypeError,
            "Regexp.group must be an int, not float")
    refuses(lambda: Regexp("extract", "a", "p"), TypeError,
            "Regexp.child must be an expression node, not str")


def test_string_fn_construction_and_refusals():
    for op in _vocab.STRING_FNS:
        assert StringFn(op, A).op == op
    refuses(lambda: StringFn("capitalize", A), ValueError,
            "StringFn op 'capitalize' is not one of: " + one_of(_vocab.STRING_FNS))
    refuses(lambda: StringFn("upper", "a"), TypeError,
            "StringFn.child must be an expression node, not str")


def test_string_fn_n_construction_and_refusals():
    for op in _vocab.STRING_FNS_N:
        assert StringFnN(op, (A,)).op == op
    assert StringFnN("concat", (A, Lit("-"), B)).args == (A, Lit("-"), B)
    refuses(lambda: StringFnN("join", (A,)), ValueError,
            "StringFnN op 'join' is not one of: " + one_of(_vocab.STRING_FNS_N))
    refuses(lambda: StringFnN("concat", []), TypeError,
            "StringFnN.args must be a tuple, not list")
    refuses(lambda: StringFnN("concat", [A, B]), TypeError,
            "StringFnN.args must be a tuple, not list")
    refuses(lambda: StringFnN("concat", ()), ValueError, "StringFnN needs at least one argument")
    refuses(lambda: StringFnN("concat", (A, "b")), TypeError,
            "StringFnN.args[1] must be an expression node, not str")


def test_substring_construction_and_boundaries():
    assert Substring(A, 1).length is None
    assert Substring(A, 1, 0).length == 0
    assert Substring(A, -3, 2).start == -3
    assert Substring(A, 0).start == 0


def test_substring_refusals():
    refuses(lambda: Substring("a", 1), TypeError,
            "Substring.child must be an expression node, not str")
    refuses(lambda: Substring(A, True), TypeError, "Substring.start must be an int, not bool")
    refuses(lambda: Substring(A, 1.0), TypeError, "Substring.start must be an int, not float")
    refuses(lambda: Substring(A, "1"), TypeError, "Substring.start must be an int, not str")
    refuses(lambda: Substring(A, 1, False), TypeError, "Substring.length must be an int, not bool")
    refuses(lambda: Substring(A, 1, "2"), TypeError, "Substring.length must be an int, not str")
    refuses(lambda: Substring(A, 1, -1), ValueError, "Substring.length must be at least 0, not -1")


def test_math_fn_and_math_fn_2_construction_and_refusals():
    for op in _vocab.MATH_FNS:
        assert MathFn(op, A).op == op
    for op in _vocab.MATH_FNS_2:
        assert MathFn2(op, A, B).op == op
    refuses(lambda: MathFn("log", A), ValueError,
            "MathFn op 'log' is not one of: " + one_of(_vocab.MATH_FNS))
    refuses(lambda: MathFn("sqrt", 4), TypeError,
            "MathFn.child must be an expression node, not int")
    refuses(lambda: MathFn2("hypot", A, B), ValueError,
            "MathFn2 op 'hypot' is not one of: atan2, pow")
    refuses(lambda: MathFn2("pow", 2, B), TypeError,
            "MathFn2.left must be an expression node, not int")


def test_extract_construction_and_refusals():
    for unit in _vocab.EXTRACT_UNITS:
        assert Extract(unit, A).unit == unit
    refuses(lambda: Extract("decade", A), ValueError,
            "Extract op 'decade' is not one of: " + one_of(_vocab.EXTRACT_UNITS))
    refuses(lambda: Extract(1, A), TypeError, "Extract op must be a str, not int")
    refuses(lambda: Extract("year", "a"), TypeError,
            "Extract.child must be an expression node, not str")


def test_struct_field_construction_and_refusals():
    s = StructField(A, "inner")
    assert s.parent is A and s.field == "inner"
    assert StructField(StructField(A, "x"), "y") != StructField(A, "y")
    refuses(lambda: StructField("a", "f"), TypeError,
            "StructField.parent must be an expression node, not str")
    refuses(lambda: StructField(A, 1), TypeError, "StructField.field must be a str, not int")
    refuses(lambda: StructField(A, ""), ValueError, "StructField.field must not be empty")


def test_alias_construction_and_refusals():
    assert Alias(A, "x").name == "x"
    assert Alias(Arith("add", A, B), "s").child == Arith("add", A, B)
    refuses(lambda: Alias("a", "x"), TypeError, "Alias.child must be an expression node, not str")
    refuses(lambda: Alias(A, 1), TypeError, "Alias.name must be a str, not int")
    refuses(lambda: Alias(A, ""), ValueError, "Alias.name must not be empty")
    refuses(lambda: Alias(Alias(A, "x"), "y"), ValueError, "an Alias cannot wrap another Alias")


def test_nodes_nest_inside_one_another():
    expr = Alias(
        Cast(MathFn("sqrt", Arith("mul", Extract("year", A), Lit(2))), "float32", True),
        "r",
    )
    assert expr.child.child.child.left.child is A
    assert expr == dataclasses.replace(expr)


def test_is_predicate_true_cases():
    trues = [
        P,
        Compare("ne", A, B),
        BoolOp("and", P, Q),
        BoolOp("or", P, Q),
        StringOp("contains", A, "x"),
        StringOp("starts_with", A, "x"),
        StringOp("ends_with", A, "x"),
        Regexp("like", A, "p"),
        Regexp("full_match", A, "p"),
        Unary("not", P),
        Unary("is_null", A),
        Unary("is_not_null", A),
        Lit(True),
        Lit(False),
        Lit(None),
        Alias(P, "p"),
        Alias(Unary("is_null", A), "n"),
    ]
    for node in trues:
        assert is_predicate(node) is True, node


def test_is_predicate_false_cases():
    falses = [
        A,
        Lit(1),
        Lit(1.0),
        Lit("x"),
        Arith("add", A, B),
        Unary("negate", A),
        Unary("abs", A),
        Unary("round", A),
        RoundDigits("round", A, 1),
        Regexp("match", A, "p"),
        Regexp("replace", A, "p", "r"),
        Regexp("extract", A, "p"),
        Regexp("count", A, "p"),
        Cast(A, "bool"),
        When(((P, Lit(True)),), Lit(False)),
        StringFn("upper", A),
        StringFnN("concat", (A,)),
        Substring(A, 1),
        MathFn("sqrt", A),
        MathFn2("pow", A, B),
        Extract("year", A),
        StructField(A, "f"),
        Alias(A, "x"),
        Alias(Arith("add", A, B), "x"),
    ]
    for node in falses:
        assert is_predicate(node) is False, node
    assert is_predicate("not a node") is False
    assert is_predicate(None) is False


def test_and_all_and_or_all_chain_to_the_left_in_order():
    r = Compare("lt", C, Lit(3))
    assert and_all((P, Q, r)) == BoolOp("and", BoolOp("and", P, Q), r)
    assert or_all((P, Q, r)) == BoolOp("or", BoolOp("or", P, Q), r)
    assert and_all((P, Q)) == BoolOp("and", P, Q)
    assert or_all((Q, P)) == BoolOp("or", Q, P)


def test_and_all_and_or_all_boundaries():
    assert and_all(()) is None
    assert or_all(()) is None
    assert and_all((P,)) is P
    assert or_all((P,)) is P


def test_and_all_and_or_all_refuse_a_non_predicate():
    refuses(lambda: and_all((P, A)), TypeError,
            "BoolOp and needs predicates, and its right operand is a ColRef")
    refuses(lambda: or_all((A, P)), TypeError,
            "BoolOp or needs predicates, and its left operand is a ColRef")


def test_is_in_with_no_values_is_false():
    assert is_in(A, []) == Lit(False)
    assert is_in(A, ()) == Lit(False)


def test_is_in_with_one_value_is_one_comparison():
    assert is_in(A, [5]) == Compare("eq", A, Lit(5))
    assert is_in(A, (Lit(5),)) == Compare("eq", A, Lit(5))


def test_is_in_with_three_values_is_a_left_leaning_or_chain_in_order():
    eq = lambda v: Compare("eq", A, Lit(v))  # noqa: E731
    expected = BoolOp("or", BoolOp("or", eq(1), eq(2)), eq(3))
    assert is_in(A, [1, 2, 3]) == expected
    assert is_in(A, (1, 2, 3)) == expected
    assert is_in(A, [Lit(1), 2, Lit(3)]) == expected


def test_is_in_keeps_a_none_member_as_a_null_literal():
    assert is_in(A, [1, None]) == BoolOp(
        "or", Compare("eq", A, Lit(1)), Compare("eq", A, Lit(None))
    )
    assert is_in(A, [None]) == Compare("eq", A, Lit(None))


def test_is_in_takes_a_node_value_as_is():
    assert is_in(A, [B]) == Compare("eq", A, B)


def test_is_in_accepts_exactly_64_values():
    node = is_in(A, list(range(64)))
    depth = 0
    while isinstance(node, BoolOp):
        assert node.right == Compare("eq", A, Lit(63 - depth))
        node = node.left
        depth += 1
    assert depth == 63 and node == Compare("eq", A, Lit(0))


def test_is_in_refuses_65_values_by_name():
    refuses(lambda: is_in(A, list(range(65))), UnsupportedOperation,
            "is_in takes at most 64 values, and was given 65; filter with a join instead")
    refuses(lambda: is_in(A, tuple(range(100))), UnsupportedOperation,
            "is_in takes at most 64 values, and was given 100; filter with a join instead")
    e = raised(lambda: is_in(A, list(range(65))))
    assert isinstance(e, KomiraError) and e.status is None


def test_is_in_refuses_a_child_or_values_of_the_wrong_type():
    refuses(lambda: is_in("a", [1]), TypeError,
            "is_in.child must be an expression node, not str")
    refuses(lambda: is_in(A, 5), TypeError, "is_in values must be a list or tuple, not int")
    refuses(lambda: is_in(A, {1, 2}), TypeError, "is_in values must be a list or tuple, not set")
    refuses(lambda: is_in(A, [[1]]), TypeError, "Lit cannot hold a list")


def test_between_closed_forms():
    for closed, low, high in (
        ("both", "ge", "le"),
        ("left", "ge", "lt"),
        ("right", "gt", "le"),
        ("none", "gt", "lt"),
    ):
        assert between(A, 1, 5, closed) == BoolOp(
            "and", Compare(low, A, Lit(1)), Compare(high, A, Lit(5))
        ), closed
    assert between(A, 1, 5) == between(A, 1, 5, "both")
    assert between(A, 1, 5, closed="left") == between(A, 1, 5, "left")


def test_between_wraps_scalars_and_keeps_nodes():
    assert between(A, B, 2.5, "none") == BoolOp(
        "and", Compare("gt", A, B), Compare("lt", A, Lit(2.5))
    )
    assert between(A, Lit(1), C) == BoolOp("and", Compare("ge", A, Lit(1)), Compare("le", A, C))
    assert between(A, None, None).left.right == Lit(None)


def test_between_refusals():
    refuses(lambda: between(A, 1, 2, "neither"), ValueError,
            "between closed 'neither' is not one of: both, left, right, none")
    refuses(lambda: between(A, 1, 2, ""), ValueError,
            "between closed '' is not one of: both, left, right, none")
    refuses(lambda: between("a", 1, 2), TypeError,
            "Compare.left must be an expression node, not str")
    refuses(lambda: between(A, [1], 2), TypeError, "Lit cannot hold a list")


def test_as_node_returns_a_node_and_wraps_anything_else():
    for node in (A, P, Lit(3), Alias(A, "x")):
        assert as_node(node) is node
    assert as_node(3) == Lit(3)
    assert as_node("a") == Lit("a")
    assert as_node(None) == Lit(None)
    assert as_node(True) == Lit(True)
    refuses(lambda: as_node([1]), TypeError, "Lit cannot hold a list")


def test_output_name_of_each_kind_of_node():
    assert output_name(Alias(A, "x")) == "x"
    assert output_name(ColRef("col")) == "col"
    assert output_name(ColRef("col", "left")) == "col"
    assert output_name(Alias(ColRef("col"), "renamed")) == "renamed"
    assert output_name(Lit(1)) is None
    assert output_name(Arith("add", A, B)) is None
    assert output_name(StructField(A, "f")) is None
    assert output_name(P) is None


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("ops_expr: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
