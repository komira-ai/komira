"""The Join, Union, Write and WriteTarget nodes of komira._ops, and the
behaviour of whole plans: the output columns each node derives, the renaming of
clashing right-hand columns, structural equality and hashing, the rule that a
Write is only a plan's root, and the walk over plan nodes. Every refusal is
checked by its exact exception class and message.

    test_ops_rel_join.py
"""

import dataclasses

from komira._ops import (
    PLAN_NODES,
    Agg,
    Aggregate,
    Alias,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Join,
    Limit,
    Lit,
    MapBatches,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    UdfSpec,
    Union,
    Write,
    WriteTarget,
    walk_plan,
)

FRAME_SPEC = UdfSpec(
    "m.f", "map_batches_frame", "package", "m:f", (), (("x", "int64"),), "stable", "propagate", "values", ("id",)
)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    assert e.args[0] == message, e.args[0]


def people():
    return Scan(
        "people.parquet",
        "parquet",
        (Field("id", "int64"), Field("name", "string"), Field("score", "float64")),
    )


def cities():
    return Scan("cities.parquet", "parquet", (Field("id", "int64"), Field("city", "string")))


def col(name, side=None):
    return ColRef(name, side)


def ident(name):
    return (name, col(name))


FRAME_COLUMNS = "id, name, score"


def missing(name, closest=None):
    if closest is None:
        return f"no column named '{name}' in this frame; the frame's columns are: {FRAME_COLUMNS}"
    return (
        f"no column named '{name}' in this frame; the closest is '{closest}'; "
        f"the frame's columns are: {FRAME_COLUMNS}"
    )


# ---------------------------------------------------------------------------
# Join
# ---------------------------------------------------------------------------


def test_join_output_columns_rename_clashing_right_columns():
    for how in ("inner", "left", "right", "full"):
        j = Join(people(), cities(), how, ("id",), ("id",))
        assert j.columns == ("id", "name", "score", "id_right", "city"), (how, j.columns)
    only = Scan("o.parquet", "parquet", (Field("code", "int64"), Field("city", "string")))
    j = Join(people(), only, "inner", ("id",), ("code",))
    assert j.columns == ("id", "name", "score", "code", "city"), "no clash, no rename"


def test_join_semi_and_anti_output_only_left_columns():
    for how in ("semi", "anti"):
        j = Join(people(), cities(), how, ("id",), ("id",))
        assert j.columns == ("id", "name", "score"), (how, j.columns)
    clashing = Scan("c.parquet", "parquet", (Field("id", "int64"), Field("id_right", "int64")))
    assert Join(people(), clashing, "semi", ("id",), ("id",)).columns == ("id", "name", "score"), (
        "right columns are not output, so their names cannot clash"
    )


def test_join_cross_has_no_keys_and_renames_clashes():
    j = Join(people(), cities(), "cross")
    assert j.columns == ("id", "name", "score", "id_right", "city"), j.columns
    refused(
        lambda: Join(people(), cities(), "cross", ("id",), ("id",)),
        ValueError,
        "Join cross takes no keys and no residual",
    )
    residual = Compare("eq", col("id", "left"), col("id", "right"))
    refused(
        lambda: Join(people(), cities(), "cross", residual=residual),
        ValueError,
        "Join cross takes no keys and no residual",
    )


def test_join_keyed_hows_need_keys_or_a_residual():
    for how in ("inner", "left", "right", "full", "semi", "anti"):
        refused(
            lambda: Join(people(), cities(), how),
            ValueError,
            f"Join {how} needs keys or a residual",
        )


def test_join_key_counts_must_match():
    refused(
        lambda: Join(people(), cities(), "inner", ("id", "name"), ("id",)),
        ValueError,
        "Join: left_on has 2 column(s) and right_on 1",
    )
    refused(
        lambda: Join(people(), cities(), "inner", ("id",), ()),
        ValueError,
        "Join: left_on has 1 column(s) and right_on 0",
    )
    refused(
        lambda: Join(people(), cities(), "inner", (), ("id",)),
        ValueError,
        "Join: left_on has 0 column(s) and right_on 1",
    )


def test_join_keys_are_checked_against_their_own_side():
    refused(lambda: Join(people(), cities(), "inner", ("zzz",), ("id",)), KeyError, missing("zzz"))
    refused(
        lambda: Join(people(), cities(), "inner", ("id",), ("name",)),
        KeyError,
        "no column named 'name' in this frame; the frame's columns are: id, city",
    )
    refused(
        lambda: Join(people(), cities(), "inner", ("id",), ("zzz",)),
        KeyError,
        "no column named 'zzz' in this frame; the frame's columns are: id, city",
    )


def test_join_multiple_keys_and_residual_together():
    right = Scan("r.parquet", "parquet", (Field("rid", "int64"), Field("rname", "string")))
    residual = Compare("lt", col("score", "left"), col("rid", "right"))
    j = Join(people(), right, "inner", ("id", "name"), ("rid", "rname"), residual)
    assert j.columns == ("id", "name", "score", "rid", "rname"), j.columns
    r = Join(people(), right, "left", residual=residual)
    assert r.left_on == () and r.right_on == (), "a residual alone is enough"
    assert r.residual == residual


def test_join_residual_needs_sides_on_every_column():
    refused(
        lambda: Join(
            people(), cities(), "inner", residual=Compare("eq", col("id"), col("id", "right"))
        ),
        ValueError,
        "Join residual column 'id' has no side; give it side='left' or side='right'",
    )
    refused(
        lambda: Join(
            people(),
            cities(),
            "inner",
            ("id",),
            ("id",),
            Compare("eq", col("id", "left"), col("city")),
        ),
        ValueError,
        "Join residual column 'city' has no side; give it side='left' or side='right'",
    )


def test_join_residual_columns_are_checked_on_their_side():
    refused(
        lambda: Join(
            people(), cities(), "inner", residual=Compare("eq", col("city", "left"), col("id", "right"))
        ),
        KeyError,
        "no column named 'city' in this frame; the frame's columns are: id, name, score",
    )
    refused(
        lambda: Join(
            people(), cities(), "inner", residual=Compare("eq", col("id", "left"), col("scor", "right"))
        ),
        KeyError,
        "no column named 'scor' in this frame; the frame's columns are: id, city",
    )


def test_join_residual_must_be_a_predicate_node():
    refused(
        lambda: Join(people(), cities(), "inner", residual=col("id", "left")),
        TypeError,
        "Join residual must be a predicate, not a ColRef",
    )
    refused(
        lambda: Join(people(), cities(), "inner", ("id",), ("id",), residual="id > 1"),
        TypeError,
        "Join.residual must be an expression node, not str",
    )


def test_join_refuses_a_right_rename_that_collides():
    expected = (
        "Join: the right column 'id' would be renamed 'id_right', "
        "which the frame already has; rename one first"
    )
    twice = Join(people(), cities(), "inner", ("id",), ("id",))
    refused(lambda: Join(twice, cities(), "inner", ("id",), ("id",)), ValueError, expected)
    left_has = Scan("l.parquet", "parquet", (Field("id", "int64"), Field("id_right", "int64")))
    refused(lambda: Join(left_has, cities(), "inner", ("id",), ("id",)), ValueError, expected)
    right_has = Scan("r.parquet", "parquet", (Field("id", "int64"), Field("id_right", "int64")))
    refused(lambda: Join(people(), right_has, "inner", ("id",), ("id",)), ValueError, expected)
    refused(lambda: Join(people(), right_has, "cross"), ValueError, expected)


def test_join_refuses_unknown_how_and_wrong_types():
    refused(
        lambda: Join(people(), cities(), "outer", ("id",), ("id",)),
        ValueError,
        "Join op 'outer' is not one of: anti, cross, full, inner, left, right, semi",
    )
    refused(lambda: Join(people(), cities(), 1), TypeError, "Join op must be a str, not int")
    refused(
        lambda: Join(people(), cities(), "inner", ["id"], ["id"]),
        TypeError,
        "Join.left_on must be a tuple, not list",
    )
    refused(
        lambda: Join(people(), cities(), "inner", ("id",), ["id"]),
        TypeError,
        "Join.right_on must be a tuple, not list",
    )
    refused(lambda: Join("people", cities(), "cross"), TypeError, "Join.left must be a plan node, not str")
    refused(lambda: Join(people(), None, "cross"), TypeError, "Join.right must be a plan node, not NoneType")


def test_join_equality_and_hash_are_structural():
    a = Join(people(), cities(), "inner", ("id",), ("id",))
    assert a == Join(people(), cities(), "inner", ("id",), ("id",))
    assert hash(a) == hash(Join(people(), cities(), "inner", ("id",), ("id",)))
    assert a != Join(people(), cities(), "left", ("id",), ("id",))
    assert a != Join(cities(), people(), "inner", ("id",), ("id",)), "sides are not interchangeable"


# ---------------------------------------------------------------------------
# Union
# ---------------------------------------------------------------------------


def test_union_columns_are_the_first_inputs_columns():
    u = Union((people(), Filter(people(), Lit(True)), Limit(people(), 1)))
    assert u.columns == ("id", "name", "score"), u.columns
    assert len(u.children) == 3
    assert u == Union((people(), Filter(people(), Lit(True)), Limit(people(), 1)))
    assert hash(u) == hash(Union((people(), Filter(people(), Lit(True)), Limit(people(), 1))))
    assert Union((people(), people())) != Union((people(), Limit(people(), 1)))


def test_union_refuses_a_single_input_and_wrong_types():
    refused(lambda: Union(()), ValueError, "Union needs at least two inputs")
    refused(lambda: Union((people(),)), ValueError, "Union needs at least two inputs")
    refused(lambda: Union([people(), people()]), TypeError, "Union.children must be a tuple, not list")
    refused(lambda: Union((people(), "people")), TypeError, "Union.children must be a plan node, not str")


def test_union_refuses_inputs_with_different_names_or_order():
    reordered = Project(people(), (ident("name"), ident("id"), ident("score")))
    refused(
        lambda: Union((people(), reordered)),
        ValueError,
        "Union: input 1 has columns (name, id, score), and the first input has (id, name, score)",
    )
    narrower = Project(people(), (ident("id"),))
    refused(
        lambda: Union((people(), people(), narrower)),
        ValueError,
        "Union: input 2 has columns (id), and the first input has (id, name, score)",
    )
    renamed = Project(people(), (ident("id"), ident("name"), ("points", col("score"))))
    refused(
        lambda: Union((people(), renamed)),
        ValueError,
        "Union: input 1 has columns (id, name, points), and the first input has (id, name, score)",
    )


# ---------------------------------------------------------------------------
# WriteTarget, Write
# ---------------------------------------------------------------------------


def test_write_keeps_child_columns_and_carries_its_target():
    w = Write(people(), WriteTarget("out.parquet", "parquet"))
    assert w.columns == ("id", "name", "score"), w.columns
    assert w.target == WriteTarget("out.parquet", "parquet")
    for fmt in ("parquet", "csv", "jsonl"):
        assert WriteTarget("o", fmt).format == fmt, fmt
    assert w == Write(people(), WriteTarget("out.parquet", "parquet"))
    assert hash(w) == hash(Write(people(), WriteTarget("out.parquet", "parquet")))
    assert w != Write(people(), WriteTarget("out.parquet", "csv"))
    projected = Write(Project(people(), (ident("id"),)), WriteTarget("o", "csv"))
    assert projected.columns == ("id",)


def test_write_target_refuses_bad_path_and_format():
    refused(lambda: WriteTarget("", "parquet"), ValueError, "WriteTarget.path must not be empty")
    refused(lambda: WriteTarget(1, "parquet"), TypeError, "WriteTarget.path must be a str, not int")
    refused(
        lambda: WriteTarget("o", "orc"),
        ValueError,
        "WriteTarget format op 'orc' is not one of: csv, jsonl, parquet",
    )
    refused(
        lambda: WriteTarget("o", "ndjson"),
        ValueError,
        "WriteTarget format op 'ndjson' is not one of: csv, jsonl, parquet",
    )
    refused(lambda: WriteTarget("o", None), TypeError, "WriteTarget format op must be a str, not NoneType")


def test_write_target_codec_defaults_to_none_and_is_part_of_its_identity():
    assert WriteTarget("o", "parquet").codec is None
    assert WriteTarget("o", "parquet", "zstd").codec == "zstd"
    assert WriteTarget("o", "csv", "gzip") == WriteTarget("o", "csv", "gzip")
    assert hash(WriteTarget("o", "csv", "gzip")) == hash(WriteTarget("o", "csv", "gzip"))
    assert WriteTarget("o", "csv") != WriteTarget("o", "csv", "gzip")
    assert WriteTarget("o", "csv", "gzip") != WriteTarget("o", "csv", "zstd")
    assert hash(WriteTarget("o", "csv")) != hash(WriteTarget("o", "csv", "gzip"))
    for codec in ("snappy", "uncompressed", "zstd", "gzip", "lz4"):
        assert WriteTarget("o", "parquet", codec).codec == codec, codec
    for codec in ("uncompressed", "zstd", "gzip", "lz4"):
        for fmt in ("csv", "jsonl"):
            assert WriteTarget("o", fmt, codec).codec == codec, (fmt, codec)


def test_write_target_refuses_a_bad_codec():
    refused(
        lambda: WriteTarget("o", "parquet", "brotli"),
        ValueError,
        "WriteTarget codec op 'brotli' is not one of: gzip, lz4, snappy, uncompressed, zstd",
    )
    refused(lambda: WriteTarget("o", "parquet", 3), TypeError, "WriteTarget codec op must be a str, not int")
    refused(
        lambda: WriteTarget("o", "csv", "snappy"),
        ValueError,
        "WriteTarget: no file sink writes csv with snappy",
    )
    refused(
        lambda: WriteTarget("o", "jsonl", "snappy"),
        ValueError,
        "WriteTarget: no file sink writes jsonl with snappy",
    )


def test_write_refuses_wrong_child_and_target_types():
    refused(
        lambda: Write(people(), ("o", "parquet")),
        TypeError,
        "Write.target must be a WriteTarget, not tuple",
    )
    refused(
        lambda: Write("people", WriteTarget("o", "csv")),
        TypeError,
        "Write.child must be a plan node, not str",
    )


def test_write_is_refused_as_the_child_of_any_node():
    written = Write(people(), WriteTarget("o", "csv"))
    message = "a Write can only be the root of a plan"
    key = (SortKey("id"),)
    for build in (
        lambda: Filter(written, Lit(True)),
        lambda: Project(written, (ident("id"),)),
        lambda: Aggregate(written, ("id",), ()),
        lambda: Sort(written, key),
        lambda: Limit(written, 1),
        lambda: TopN(written, key, 1),
        lambda: Distinct(written),
        lambda: Join(written, cities(), "cross"),
        lambda: Join(people(), written, "cross"),
        lambda: Union((written, people())),
        lambda: Union((people(), written)),
        lambda: Write(written, WriteTarget("p", "csv")),
    ):
        refused(build, TypeError, message)


# ---------------------------------------------------------------------------
# Whole-tree behaviour
# ---------------------------------------------------------------------------


def test_columns_flow_through_a_composed_plan():
    p = Filter(people(), Compare("gt", col("score"), Lit(0)))
    p = Aggregate(p, ("name",), (("total", Agg("sum", (col("score"),))),))
    p = Sort(p, (SortKey("total", True),))
    p = Limit(p, 3)
    p = Project(p, (("who", col("name")),))
    assert p.columns == ("who",), p.columns
    assert Write(p, WriteTarget("o.csv", "csv")).columns == ("who",)
    refused(
        lambda: Filter(p, Compare("gt", col("total"), Lit(0))),
        KeyError,
        "no column named 'total' in this frame; the frame's columns are: who",
    )


def test_derived_columns_are_not_part_of_equality_or_repr_and_nodes_are_frozen():
    a = Project(people(), (ident("id"),))
    assert "_columns" not in repr(a), repr(a)
    e = raised(lambda: setattr(a, "items", ()))
    assert type(e) is dataclasses.FrozenInstanceError, type(e)
    assert e.args[0] == "cannot assign to field 'items'", e.args[0]
    assert a == Project(people(), (ident("id"),))


def test_plan_nodes_lists_every_relational_class_once():
    names = [cls.__name__ for cls in PLAN_NODES]
    assert names == [
        "Scan",
        "Filter",
        "Project",
        "Aggregate",
        "Sort",
        "Limit",
        "TopN",
        "Distinct",
        "Join",
        "Union",
        "Write",
        "MapBatches",
    ], names
    for node in (
        people(),
        Filter(people(), Lit(True)),
        Project(people(), (ident("id"),)),
        Aggregate(people(), (), (("n", Agg("count")),)),
        Sort(people(), (SortKey("id"),)),
        Limit(people(), 1),
        TopN(people(), (SortKey("id"),), 1),
        Distinct(people()),
        Join(people(), cities(), "cross"),
        Union((people(), people())),
        Write(people(), WriteTarget("o", "csv")),
        MapBatches(people(), FRAME_SPEC),
    ):
        assert isinstance(node, PLAN_NODES), type(node).__name__
        assert isinstance(node.columns, tuple), type(node).__name__


def test_walk_plan_is_pre_order_and_visits_join_sides_and_union_inputs():
    left, right = people(), cities()
    j = Join(left, right, "inner", ("id",), ("id",))
    root = Write(Limit(Filter(j, Lit(True)), 2), WriteTarget("o", "csv"))
    visited = list(walk_plan(root))
    assert [type(n).__name__ for n in visited] == [
        "Write",
        "Limit",
        "Filter",
        "Join",
        "Scan",
        "Scan",
    ], visited
    assert visited[4] is left and visited[5] is right, "left before right"
    a, b, c = people(), Limit(people(), 1), Distinct(people())
    u = Union((a, b, c))
    assert [type(n).__name__ for n in walk_plan(u)] == [
        "Union",
        "Scan",
        "Limit",
        "Scan",
        "Distinct",
        "Scan",
    ]
    assert list(walk_plan(left)) == [left], "a scan is a leaf"


def test_walk_plan_refuses_a_non_plan_object():
    refused(lambda: list(walk_plan("people")), TypeError, "not a plan node: str")
    refused(lambda: list(walk_plan(Lit(1))), TypeError, "not a plan node: Lit")
    refused(lambda: list(walk_plan(Alias(Lit(1), "a"))), TypeError, "not a plan node: Alias")


def main():
    tests = [
        value
        for name, value in list(globals().items())
        if name.startswith("test_") and callable(value) and value.__module__ == __name__
    ]
    for test in tests:
        test()
    print(f"test_ops_rel_join: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
