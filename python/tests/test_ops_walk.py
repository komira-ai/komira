"""The walkers over expression trees in komira._ops: children in field order
for every node class, pre-order walk, column references and the names they
carry, substitution (what is replaced, what keeps its identity, what is left
alone) and the leftmost column. An object that is not an expression node is a
TypeError in every walker.

    test_ops_walk.py
"""

import dataclasses
import inspect

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
    UdfCall,
    UdfSpec,
    Unary,
    When,
    children,
    column_refs,
    leftmost_column,
    referenced_columns,
    substitute,
    walk,
)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


A = ColRef("a")
B = ColRef("b")
C = ColRef("c")
ONE = Lit(1)
SCALAR = UdfSpec("m.g", "scalar", "package", "m:g", (), "int64", "immutable", "propagate", "values")


def one_of_each():
    """One instance of every expression class, each with distinct leaves."""
    p = Compare("eq", A, ONE)
    return {
        ColRef: A,
        Lit: ONE,
        Compare: p,
        Arith: Arith("add", A, B),
        BoolOp: BoolOp("and", p, Compare("gt", B, ONE)),
        Unary: Unary("negate", A),
        RoundDigits: RoundDigits("round_half_even", A, -1),
        Cast: Cast(A, "int64"),
        When: When(((p, A), (Compare("lt", B, ONE), B)), C),
        StringOp: StringOp("contains", A, "x"),
        Regexp: Regexp("match", A, "x"),
        StringFn: StringFn("upper", A),
        StringFnN: StringFnN("concat", (A, B, C)),
        Substring: Substring(A, 1, 2),
        MathFn: MathFn("sqrt", A),
        MathFn2: MathFn2("pow", A, B),
        Extract: Extract("year", A),
        StructField: StructField(A, "f"),
        Alias: Alias(A, "out"),
        UdfCall: UdfCall(SCALAR, (A, B)),
    }


class NotANode:
    pass


def test_every_node_class_is_covered_by_the_fixture():
    nodes = one_of_each()
    assert set(nodes) == set(EXPR_NODES), "the fixture misses a node class"
    for cls, node in nodes.items():
        assert type(node) is cls, (cls, node)


def test_children_of_a_leaf_is_empty():
    assert children(A) == (), children(A)
    assert children(ONE) == (), children(ONE)
    assert children(Lit(None)) == (), "a null literal has no children"


def test_children_of_two_operand_nodes_are_left_then_right():
    for node in (
        Compare("lt", A, B),
        Arith("sub", A, B),
        BoolOp("or", Compare("eq", A, B), Compare("ne", A, B)),
        MathFn2("atan2", A, B),
    ):
        assert children(node) == (node.left, node.right), node
    assert children(Arith("sub", A, B)) == (A, B)


def test_children_of_one_operand_nodes_is_the_child():
    for node in (
        Unary("abs", A),
        RoundDigits("trunc", A, 2),
        Cast(A, "float64", True),
        StringOp("starts_with", A, "p"),
        Regexp("extract", A, "(x)", group=1),
        StringFn("lower", A),
        Substring(A, -2),
        MathFn("floor", A),
        Extract("trunc_month", A),
        Alias(A, "z"),
    ):
        assert children(node) == (A,), node
        assert children(node)[0] is node.child, node


def test_children_of_struct_field_is_the_parent():
    inner = StructField(A, "x")
    outer = StructField(inner, "y")
    assert children(outer) == (inner,), children(outer)
    assert children(inner) == (A,), children(inner)


def test_children_of_string_fn_n_are_its_args_in_order():
    node = StringFnN("concat_ws", (C, A, B, A))
    assert children(node) == (C, A, B, A), children(node)
    assert children(StringFnN("replace", (A,))) == (A,), "one argument is allowed"


def test_children_of_when_alternate_condition_result_then_default():
    c0, r0 = Compare("eq", A, ONE), Lit("one")
    c1, r1 = Compare("eq", A, Lit(2)), Lit("two")
    default = Lit("many")
    node = When(((c0, r0), (c1, r1)), default)
    assert children(node) == (c0, r0, c1, r1, default), children(node)
    single = When(((c0, r0),), default)
    assert children(single) == (c0, r0, default), children(single)


def test_children_returns_a_tuple_for_every_class():
    for cls, node in one_of_each().items():
        got = children(node)
        assert type(got) is tuple, (cls.__name__, type(got))
        assert all(isinstance(x, EXPR_NODES) for x in got), cls.__name__


def test_walk_of_a_leaf_yields_just_the_leaf():
    assert list(walk(A)) == [A]
    assert list(walk(ONE)) == [ONE]


def test_walk_is_pre_order_parent_before_children():
    left = Arith("add", A, B)
    right = Arith("mul", C, ONE)
    root = Compare("lt", left, right)
    assert list(walk(root)) == [root, left, A, B, right, C, ONE], list(walk(root))


def test_walk_of_when_follows_the_children_order():
    c0 = Compare("eq", A, ONE)
    r0 = Arith("add", B, ONE)
    c1 = Compare("eq", C, ONE)
    r1 = StringFn("upper", B)
    default = Cast(A, "int8")
    node = When(((c0, r0), (c1, r1)), default)
    got = list(walk(node))
    assert got == [node, c0, A, ONE, r0, B, ONE, c1, C, ONE, r1, B, default, A], got


def test_walk_is_a_lazy_generator():
    it = walk(Arith("add", A, B))
    assert inspect.isgenerator(it), type(it)
    assert next(it) == Arith("add", A, B)
    assert next(it) == A


def test_walk_visits_every_class_once_from_a_tree_holding_them_all():
    nodes = one_of_each()
    root = StringFnN("concat", tuple(nodes[c] for c in (Arith, Cast, When, Alias)))
    seen = {type(n) for n in walk(root)}
    assert {Arith, Cast, When, Alias, ColRef, Lit, Compare, StringFnN} <= seen, seen


def test_walk_of_a_deep_chain_visits_each_level_once():
    node = A
    for _ in range(50):
        node = Unary("negate", node)
    got = list(walk(node))
    assert len(got) == 51, len(got)
    assert got[0] is node and got[-1] == A


def test_column_refs_are_in_pre_order_with_repeats_kept():
    node = Compare("lt", Arith("add", A, B), Arith("mul", A, C))
    assert column_refs(node) == (A, B, A, C), column_refs(node)


def test_column_refs_keep_the_side_of_each_reference():
    left = ColRef("k", "left")
    right = ColRef("k", "right")
    node = Compare("eq", left, right)
    assert column_refs(node) == (left, right), column_refs(node)


def test_column_refs_of_a_tree_without_columns_is_empty():
    node = Arith("add", Lit(1), Lit(2))
    assert column_refs(node) == (), column_refs(node)
    assert type(column_refs(node)) is tuple


def test_column_refs_look_inside_when_and_string_fn_n_and_struct_field():
    node = StringFnN(
        "concat",
        (
            StructField(A, "f"),
            When(((Compare("eq", B, ONE), Lit("x")),), C),
        ),
    )
    assert column_refs(node) == (A, B, C), column_refs(node)


def test_referenced_columns_is_the_set_of_names():
    node = Compare("lt", Arith("add", A, B), Arith("mul", A, C))
    got = referenced_columns(node)
    assert got == frozenset({"a", "b", "c"}), got
    assert type(got) is frozenset


def test_referenced_columns_merges_both_sides_of_one_name():
    node = Compare("eq", ColRef("k", "left"), ColRef("k", "right"))
    assert referenced_columns(node) == frozenset({"k"}), referenced_columns(node)


def test_referenced_columns_of_a_literal_is_empty():
    assert referenced_columns(ONE) == frozenset(), referenced_columns(ONE)


def test_substitute_replaces_a_matching_column():
    got = substitute(A, {"a": Lit(7)})
    assert got == Lit(7), got
    node = Arith("add", A, B)
    assert substitute(node, {"a": Lit(7)}) == Arith("add", Lit(7), B)


def test_substitute_replaces_every_occurrence():
    node = Compare("lt", Arith("add", A, B), Arith("mul", A, C))
    got = substitute(node, {"a": Lit(0)})
    assert got == Compare("lt", Arith("add", Lit(0), B), Arith("mul", Lit(0), C)), got


def test_substitute_replaces_several_names_at_once():
    node = Arith("add", A, B)
    got = substitute(node, {"a": B, "b": A})
    assert got == Arith("add", B, A), "the replacements are not substituted again"


def test_substitute_does_not_substitute_inside_a_replacement():
    got = substitute(A, {"a": Arith("add", A, B), "b": Lit(1)})
    assert got == Arith("add", A, B), got


def test_substitute_keeps_identity_when_nothing_matches():
    node = Compare("lt", Arith("add", A, B), C)
    assert substitute(node, {"z": Lit(1)}) is node
    assert substitute(node, {}) is node
    assert substitute(A, {"z": Lit(1)}) is A


def test_substitute_keeps_untouched_subtrees_by_identity():
    left = Arith("add", A, B)
    right = Arith("mul", C, ONE)
    node = Compare("lt", left, right)
    got = substitute(node, {"c": Lit(5)})
    assert got == Compare("lt", left, Arith("mul", Lit(5), ONE)), got
    assert got.left is left, "the unchanged left subtree is shared"
    assert got is not node


def test_substitute_leaves_sided_references_alone():
    sided = ColRef("a", "left")
    node = Compare("eq", sided, A)
    got = substitute(node, {"a": Lit(1)})
    assert got == Compare("eq", sided, Lit(1)), got
    assert got.left is sided
    only_sided = Compare("eq", sided, ColRef("a", "right"))
    assert substitute(only_sided, {"a": Lit(1)}) is only_sided


def test_substitute_rebuilds_every_node_class():
    for cls, node in one_of_each().items():
        got = substitute(node, {"a": Lit(9), "b": Lit(9), "c": Lit(9)})
        if cls is Lit:
            assert got is node, "a literal has nothing to replace"
        elif cls is ColRef:
            assert got == Lit(9), got
        else:
            assert type(got) is cls, cls.__name__
            assert Lit(9) in list(walk(got)), cls.__name__
            assert referenced_columns(got) == frozenset(), (cls.__name__, got)
            assert got != node, cls.__name__


def test_substitute_keeps_the_other_fields_of_a_rebuilt_node():
    got = substitute(Cast(A, "uint16", True), {"a": B})
    assert got == Cast(B, "uint16", True), got
    got = substitute(Regexp("replace", A, "p", "r", "i"), {"a": B})
    assert got == Regexp("replace", B, "p", "r", "i"), got
    got = substitute(Substring(A, -3, 2), {"a": B})
    assert got == Substring(B, -3, 2), got
    got = substitute(Alias(A, "out"), {"a": B})
    assert got == Alias(B, "out"), got
    got = substitute(StructField(A, "f"), {"a": B})
    assert got == StructField(B, "f"), got
    got = substitute(RoundDigits("round_half_even", A, -2), {"a": B})
    assert got == RoundDigits("round_half_even", B, -2), got
    got = substitute(Extract("trunc_day", A), {"a": B})
    assert got == Extract("trunc_day", B), got


def test_substitute_rebuilds_when_in_case_order():
    c0, c1 = Compare("eq", A, ONE), Compare("eq", B, ONE)
    node = When(((c0, A), (c1, B)), C)
    got = substitute(node, {"a": Lit("A"), "c": Lit("C")})
    want = When(((Compare("eq", Lit("A"), ONE), Lit("A")), (c1, B)), Lit("C"))
    assert got == want, got
    assert got.cases[1][0] is c1, "an unchanged case condition is shared"


def test_substitute_rebuilds_string_fn_n_args_in_order():
    node = StringFnN("concat_ws", (A, B, C))
    got = substitute(node, {"b": Lit("-")})
    assert got == StringFnN("concat_ws", (A, Lit("-"), C)), got
    assert type(got.args) is tuple


def test_substitute_leaves_the_input_tree_unchanged():
    node = Arith("add", A, B)
    before = dataclasses.replace(node)
    substitute(node, {"a": Lit(1)})
    assert node == before == Arith("add", A, B)


def test_substitute_revalidates_a_rebuilt_node():
    node = Unary("not", Compare("eq", A, ONE))
    assert substitute(node, {"a": B}) == Unary("not", Compare("eq", B, ONE))
    wrapped = Alias(A, "x")
    e = raised(lambda: substitute(Alias(A, "y"), {"a": wrapped}))
    assert type(e) is ValueError, type(e)
    assert e.args[0] == "an Alias cannot wrap another Alias", e.args


def test_leftmost_column_is_the_first_in_pre_order():
    node = Arith("add", Arith("mul", B, A), C)
    assert leftmost_column(node) == "b", leftmost_column(node)
    assert leftmost_column(A) == "a"


def test_leftmost_column_skips_leading_literals():
    node = Arith("add", Lit(1), Arith("mul", Lit(2), C))
    assert leftmost_column(node) == "c", leftmost_column(node)


def test_leftmost_column_looks_into_when_condition_before_result():
    node = When(((Compare("eq", B, ONE), A),), C)
    assert leftmost_column(node) == "b", leftmost_column(node)
    only_default = When(((Compare("eq", Lit(1), ONE), Lit(2)),), C)
    assert leftmost_column(only_default) == "c"


def test_leftmost_column_of_a_tree_without_columns_is_none():
    assert leftmost_column(Lit(3)) is None
    assert leftmost_column(Arith("add", Lit(1), Lit(2))) is None


def test_leftmost_column_ignores_the_side_and_the_alias_name():
    assert leftmost_column(ColRef("k", "right")) == "k"
    assert leftmost_column(Alias(B, "out")) == "b", "the alias name is not a column"


def test_every_walker_refuses_an_object_that_is_not_a_node():
    message = "not an expression node: NotANode"
    for call in (
        lambda: children(NotANode()),
        lambda: list(walk(NotANode())),
        lambda: column_refs(NotANode()),
        lambda: referenced_columns(NotANode()),
        lambda: substitute(NotANode(), {}),
        lambda: leftmost_column(NotANode()),
    ):
        e = raised(call)
        assert type(e) is TypeError, type(e)
        assert e.args[0] == message, e.args


def test_every_walker_names_the_type_of_a_builtin_it_refuses():
    for value, name in (("a", "str"), (1, "int"), (None, "NoneType"), ([A], "list"), ((A,), "tuple")):
        for call in (
            lambda: children(value),
            lambda: list(walk(value)),
            lambda: column_refs(value),
            lambda: leftmost_column(value),
            lambda: substitute(value, {}),
        ):
            e = raised(call)
            assert type(e) is TypeError, (value, type(e))
            assert e.args[0] == f"not an expression node: {name}", e.args


def test_walk_refuses_a_non_node_only_when_iterated():
    it = walk(NotANode())
    assert inspect.isgenerator(it), "walk returns a generator"
    e = raised(lambda: next(it))
    assert type(e) is TypeError, type(e)
    assert e.args[0] == "not an expression node: NotANode", e.args


def main():
    tests = [
        (name, fn)
        for name, fn in list(globals().items())
        if name.startswith("test_") and inspect.isfunction(fn)
    ]
    for _, fn in tests:
        fn()
    print(f"test_ops_walk: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
