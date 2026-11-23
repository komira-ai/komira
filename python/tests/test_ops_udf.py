"""The user-function nodes of komira._ops: UdfSpec and UdfCall construction
and every refusal (exact class and full message), UdfCall under the walkers,
the MapBatches plan node, its output columns and refusals, and the
map_batches verb.

    test_ops_udf.py
"""

import sys

from komira._ops import (
    Alias,
    Arith,
    ColRef,
    Compare,
    Filter,
    Field,
    Limit,
    Lit,
    MapBatches,
    Project,
    Scan,
    UdfCall,
    UdfSpec,
    Write,
    WriteTarget,
    children,
    column_refs,
    is_predicate,
    leftmost_column,
    map_batches,
    output_name,
    referenced_columns,
    substitute,
    walk,
    walk_plan,
)

A = ColRef("a")
B = ColRef("b")
DIGEST = bytes(range(32))
OTHER = bytes(range(1, 33))


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def scalar(**over):
    fields = dict(
        name="m.g",
        kind="scalar",
        form="package",
        entry="m:g",
        code=(),
        return_type="int64",
        stability="immutable",
        null_mode="propagate",
        batch_format="values",
    )
    fields.update(over)
    return UdfSpec(**fields)


def row(**over):
    fields = dict(name="m.r", kind="row", entry="m:r", read_set=("a", "b"))
    fields.update(over)
    return scalar(**fields)


def frame(**over):
    fields = dict(
        name="m.f",
        kind="map_batches_frame",
        entry="m:f",
        return_type=(("x", "int64"), ("y", "float64")),
        read_set=("a",),
    )
    fields.update(over)
    return scalar(**fields)


def people():
    return Scan(
        "people.parquet",
        "parquet",
        (Field("id", "int64"), Field("name", "string"), Field("score", "float64")),
    )


def test_a_spec_of_each_kind_is_built_and_compares_by_value():
    assert scalar().read_set is None
    assert row().read_set == ("a", "b")
    assert frame().return_type == (("x", "int64"), ("y", "float64"))
    assert scalar(kind="map_batches_column") == scalar(kind="map_batches_column")
    assert scalar() != scalar(entry="m:h")
    assert hash(frame()) == hash(frame())
    bundle = scalar(form="bundle", code=(("bundle", DIGEST),))
    assert bundle.code == (("bundle", DIGEST),)
    assert row(read_set=()).read_set == ()


def test_name_and_entry_refusals():
    refuses(lambda: scalar(name=1), TypeError, "UdfSpec.name must be a str, not int")
    refuses(lambda: scalar(name=""), ValueError, "UdfSpec.name must not be empty")
    refuses(lambda: scalar(entry=None), TypeError, "UdfSpec.entry must be a str, not NoneType")
    refuses(lambda: scalar(entry=""), ValueError, "UdfSpec.entry must not be empty")
    for bad in ("abc", "a:b:c", ":b", "a:"):
        refuses(
            lambda: scalar(entry=bad),
            ValueError,
            f"UdfSpec.entry must be 'module:qualname', not {bad!r}",
        )


def test_kind_and_form_refusals():
    refuses(lambda: scalar(kind=3), TypeError, "UdfSpec kind op must be a str, not int")
    refuses(
        lambda: scalar(kind="aggregate"),
        ValueError,
        "UdfSpec kind op 'aggregate' is not one of: map_batches_column, map_batches_frame, row, scalar",
    )
    refuses(lambda: scalar(form=None), TypeError, "UdfSpec form op must be a str, not NoneType")
    refuses(
        lambda: scalar(form="value"),
        ValueError,
        "UdfSpec form op 'value' is not one of: bundle, package",
    )


def test_code_refusals():
    refuses(lambda: scalar(code=[]), TypeError, "UdfSpec.code must be a tuple, not list")
    refuses(
        lambda: scalar(form="bundle", code=("bundle",)),
        TypeError,
        "UdfSpec.code holds (role, sha256) pairs with a non-empty role",
    )
    refuses(
        lambda: scalar(form="bundle", code=(("bundle", DIGEST, 1),)),
        TypeError,
        "UdfSpec.code holds (role, sha256) pairs with a non-empty role",
    )
    refuses(
        lambda: scalar(form="bundle", code=(("", DIGEST),)),
        TypeError,
        "UdfSpec.code holds (role, sha256) pairs with a non-empty role",
    )
    refuses(
        lambda: scalar(form="bundle", code=((1, DIGEST),)),
        TypeError,
        "UdfSpec.code holds (role, sha256) pairs with a non-empty role",
    )
    refuses(
        lambda: scalar(form="bundle", code=(("bundle", "x" * 32),)),
        ValueError,
        "UdfSpec.code digests are 32 bytes",
    )
    refuses(
        lambda: scalar(form="bundle", code=(("bundle", DIGEST[:31]),)),
        ValueError,
        "UdfSpec.code digests are 32 bytes",
    )
    want = "UdfSpec.code is one ('bundle', sha256) for a bundle and empty for a package"
    refuses(lambda: scalar(form="bundle", code=()), ValueError, want)
    refuses(lambda: scalar(form="package", code=(("bundle", DIGEST),)), ValueError, want)
    refuses(lambda: scalar(form="bundle", code=(("payload", DIGEST),)), ValueError, want)
    refuses(
        lambda: scalar(form="bundle", code=(("bundle", DIGEST), ("bundle", OTHER))),
        ValueError,
        want,
    )


def test_return_type_refusals_of_a_column_kind():
    refuses(lambda: scalar(return_type=7), TypeError, "UdfSpec return_type op must be a str, not int")
    refuses(
        lambda: scalar(return_type="string"),
        ValueError,
        "UdfSpec return_type op 'string' is not one of: float64, int32, int64",
    )
    refuses(
        lambda: scalar(return_type=(("x", "int64"),)),
        TypeError,
        "UdfSpec return_type op must be a str, not tuple",
    )


def test_return_type_refusals_of_a_frame():
    refuses(
        lambda: frame(return_type="int64"),
        TypeError,
        "UdfSpec.return_type must be a tuple, not str",
    )
    refuses(
        lambda: frame(return_type=("x",)),
        TypeError,
        "UdfSpec.return_type of a frame holds (name, dtype) pairs",
    )
    refuses(
        lambda: frame(return_type=(("x", "int64", 1),)),
        TypeError,
        "UdfSpec.return_type of a frame holds (name, dtype) pairs",
    )
    refuses(
        lambda: frame(return_type=(("", "int64"),)),
        ValueError,
        "UdfSpec.return_type name must not be empty",
    )
    refuses(
        lambda: frame(return_type=((1, "int64"),)),
        TypeError,
        "UdfSpec.return_type name must be a str, not int",
    )
    refuses(
        lambda: frame(return_type=(("x", "bool"),)),
        ValueError,
        "UdfSpec return_type dtype op 'bool' is not one of: float64, int32, int64",
    )
    refuses(
        lambda: frame(return_type=()),
        ValueError,
        "UdfSpec.return_type of a frame names at least one column",
    )
    refuses(
        lambda: frame(return_type=(("x", "int64"), ("x", "float64"))),
        ValueError,
        "UdfSpec.return_type of a frame repeats a column name",
    )


def test_declaration_refusals():
    refuses(
        lambda: scalar(stability="always"),
        ValueError,
        "UdfSpec stability op 'always' is not one of: immutable, stable, volatile",
    )
    refuses(
        lambda: scalar(null_mode="skip"),
        ValueError,
        "UdfSpec null_mode op 'skip' is not one of: manual, propagate",
    )
    refuses(
        lambda: scalar(batch_format="pandas"),
        ValueError,
        "UdfSpec batch_format op 'pandas' is not one of: arrow, values",
    )
    refuses(lambda: scalar(stability=None), TypeError, "UdfSpec stability op must be a str, not NoneType")


def test_read_set_refusals():
    refuses(
        lambda: row(read_set=None),
        ValueError,
        "UdfSpec.read_set is required for a row function",
    )
    refuses(
        lambda: frame(read_set=None),
        ValueError,
        "UdfSpec.read_set is required for a map_batches_frame function",
    )
    refuses(lambda: row(read_set=["a"]), TypeError, "UdfSpec.read_set must be a tuple, not list")
    refuses(lambda: row(read_set=("a", 2)), TypeError, "UdfSpec.read_set name must be a str, not int")
    refuses(lambda: row(read_set=("",)), ValueError, "UdfSpec.read_set name must not be empty")
    unsorted = "UdfSpec.read_set must ascend by UTF-8 bytes with no repeats"
    refuses(lambda: row(read_set=("b", "a")), ValueError, unsorted)
    refuses(lambda: row(read_set=("a", "a")), ValueError, unsorted)
    refuses(lambda: row(read_set=("é", "z")), ValueError, unsorted)
    assert row(read_set=("z", "é")).read_set == ("z", "é")
    refuses(
        lambda: scalar(read_set=("a",)),
        ValueError,
        "UdfSpec.read_set is only for a row or map_batches_frame function, not scalar",
    )
    refuses(
        lambda: scalar(kind="map_batches_column", read_set=()),
        ValueError,
        "UdfSpec.read_set is only for a row or map_batches_frame function, not map_batches_column",
    )


def test_a_call_of_a_column_function():
    call = UdfCall(scalar(), (A, Arith("add", A, B)))
    assert call.args == (A, Arith("add", A, B))
    assert UdfCall(scalar(kind="map_batches_column"), (A,)).udf.kind == "map_batches_column"
    assert UdfCall(row(), (ColRef("a"), ColRef("b"))).args == (A, B)
    assert UdfCall(row(read_set=()), ()).args == ()
    assert hash(call) == hash(UdfCall(scalar(), (A, Arith("add", A, B))))
    assert call != UdfCall(scalar(), (A,))


def test_call_refusals():
    refuses(lambda: UdfCall("g", (A,)), TypeError, "UdfCall.udf must be a UdfSpec, not str")
    refuses(
        lambda: UdfCall(frame(), (A,)),
        ValueError,
        "UdfCall calls a column function, and m.f is a map_batches_frame function",
    )
    refuses(lambda: UdfCall(scalar(), [A]), TypeError, "UdfCall.args must be a tuple, not list")
    refuses(
        lambda: UdfCall(scalar(), (A, "b")),
        TypeError,
        "UdfCall.args must be an expression node, not str",
    )
    refuses(
        lambda: UdfCall(scalar(), ()),
        ValueError,
        "UdfCall of m.g takes at least one argument",
    )
    want = "UdfCall of the row function m.r passes exactly its read set's columns"
    refuses(lambda: UdfCall(row(), (A,)), ValueError, want)
    refuses(lambda: UdfCall(row(), (B, A)), ValueError, want)
    refuses(lambda: UdfCall(row(), (A, Arith("add", A, B))), ValueError, want)
    refuses(lambda: UdfCall(row(), ()), ValueError, want)
    refuses(lambda: UdfCall(row(), (A, ColRef("b", "left"))), ValueError, want)


def test_a_call_is_a_node_with_no_output_name_and_is_no_predicate():
    call = UdfCall(scalar(), (A,))
    assert output_name(call) is None
    assert not is_predicate(call)
    assert output_name(Alias(call, "r")) == "r"
    assert not is_predicate(Alias(call, "r"))


def test_the_walkers_read_the_arguments_of_a_call():
    inner = UdfCall(scalar(kind="map_batches_column"), (B,))
    call = UdfCall(scalar(), (A, inner))
    assert children(call) == (A, inner)
    assert children(inner) == (B,)
    assert list(walk(call)) == [call, A, inner, B]
    assert column_refs(call) == (A, B)
    assert referenced_columns(call) == frozenset({"a", "b"})
    assert leftmost_column(call) == "a"
    assert leftmost_column(UdfCall(scalar(), (Lit(1), A))) == "a"


def test_substitute_rebuilds_a_call_around_its_new_arguments():
    inner = UdfCall(scalar(kind="map_batches_column"), (B,))
    call = UdfCall(scalar(), (A, inner))
    got = substitute(call, {"b": Lit(2), "a": Arith("add", A, Lit(1))})
    assert got == UdfCall(
        scalar(), (Arith("add", A, Lit(1)), UdfCall(scalar(kind="map_batches_column"), (Lit(2),)))
    )
    assert got.udf is call.udf
    assert substitute(call, {"z": Lit(1)}) is call


def test_a_project_and_a_filter_check_the_columns_a_call_reads():
    call = UdfCall(scalar(), (ColRef("score"),))
    assert Project(people(), (("r", call),)).columns == ("r",)
    refuses(
        lambda: Project(people(), (("r", UdfCall(scalar(), (ColRef("scor"),))),)),
        KeyError,
        "no column named 'scor' in this frame; the closest is 'score'; "
        "the frame's columns are: id, name, score",
    )
    refuses(
        lambda: Filter(people(), call),
        TypeError,
        "Filter needs a predicate, not a UdfCall",
    )
    assert Filter(people(), Compare("gt", call, Lit(1))).columns == ("id", "name", "score")


def test_map_batches_outputs_the_columns_of_the_return_type():
    plan = MapBatches(people(), frame(read_set=("id",)))
    assert plan.columns == ("x", "y")
    assert MapBatches(people(), frame(read_set=())).columns == ("x", "y")
    assert MapBatches(people(), frame(read_set=("id", "name"), return_type=(("only", "int32"),))).columns == (
        "only",
    )
    assert plan == MapBatches(people(), frame(read_set=("id",)))
    assert hash(plan) == hash(MapBatches(people(), frame(read_set=("id",))))
    assert plan != MapBatches(people(), frame(read_set=("name",)))
    assert "_columns" not in repr(plan)


def test_map_batches_sits_above_and_below_other_nodes():
    plan = Limit(MapBatches(Project(people(), (("k", ColRef("id")),)), frame(read_set=("k",))), 3)
    assert plan.columns == ("x", "y")
    again = MapBatches(plan, frame(read_set=("x", "y")))
    assert again.columns == ("x", "y")
    root = Write(again, WriteTarget("o.parquet", "parquet"))
    assert [type(n).__name__ for n in walk_plan(root)] == [
        "Write",
        "MapBatches",
        "Limit",
        "MapBatches",
        "Project",
        "Scan",
    ]


def test_map_batches_refusals():
    refuses(
        lambda: MapBatches("people", frame()),
        TypeError,
        "MapBatches.child must be a plan node, not str",
    )
    refuses(
        lambda: MapBatches(Write(people(), WriteTarget("o.parquet", "parquet")), frame()),
        TypeError,
        "a Write can only be the root of a plan",
    )
    refuses(
        lambda: MapBatches(people(), "f"),
        TypeError,
        "MapBatches.udf must be a UdfSpec, not str",
    )
    refuses(
        lambda: MapBatches(people(), scalar()),
        ValueError,
        "MapBatches runs a map_batches_frame function, and m.g is a scalar function",
    )
    refuses(
        lambda: MapBatches(people(), row(read_set=("id",))),
        ValueError,
        "MapBatches runs a map_batches_frame function, and m.r is a row function",
    )
    refuses(
        lambda: MapBatches(people(), frame(read_set=("scor",))),
        KeyError,
        "no column named 'scor' in this frame; the closest is 'score'; "
        "the frame's columns are: id, name, score",
    )
    refuses(
        lambda: MapBatches(people(), frame(read_set=("id", "zz"))),
        KeyError,
        "no column named 'zz' in this frame; the frame's columns are: id, name, score",
    )


def test_the_map_batches_verb_builds_the_node_and_checks_its_arguments():
    udf = frame(read_set=("id",))
    assert map_batches(people(), udf) == MapBatches(people(), udf)
    refuses(
        lambda: map_batches("people", udf),
        TypeError,
        "map_batches plan must be a plan node, not str",
    )
    refuses(
        lambda: map_batches(people(), scalar()),
        ValueError,
        "MapBatches runs a map_batches_frame function, and m.g is a scalar function",
    )


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("ops_udf: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
