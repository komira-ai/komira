"""The support types (Field, SortKey, Agg, Frame, WindowExpr) and the Scan,
Filter, Project, Aggregate, Sort, TopN, Limit, Distinct and Unnest nodes of
komira._ops: the output columns each node derives, structural equality and
hashing, and every refusal with its exact exception class and message. Join,
Union and Write are in test_ops_rel_join.py.

    test_ops_rel.py
"""

from komira._ops import (
    Agg,
    Aggregate,
    Alias,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Frame,
    Limit,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Unary,
    Unnest,
    WindowExpr,
    walk_plan,
    unnest,
)
from komira._ops._vocab import AGG_FUNCS, WINDOW_FUNCS


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
# Field, SortKey
# ---------------------------------------------------------------------------


def test_field_holds_name_and_dtype_token():
    f = Field("id", "int64")
    assert (f.name, f.dtype) == ("id", "int64"), f
    assert f == Field("id", "int64"), "equal by structure"
    assert hash(f) == hash(Field("id", "int64")), "hash by structure"
    assert f != Field("id", "int32"), "dtype is part of the identity"
    assert repr(f) == "Field(name='id', dtype='int64')", repr(f)


def test_field_refuses_empty_and_non_str_parts():
    refused(lambda: Field("", "int64"), ValueError, "Field.name must not be empty")
    refused(lambda: Field("id", ""), ValueError, "Field.dtype must not be empty")
    refused(lambda: Field(1, "int64"), TypeError, "Field.name must be a str, not int")
    refused(lambda: Field("id", None), TypeError, "Field.dtype must be a str, not NoneType")


def test_sortkey_defaults_and_equality():
    k = SortKey("id")
    assert (k.column, k.descending, k.nulls_first) == ("id", False, False), k
    assert k == SortKey("id", False, False)
    assert k != SortKey("id", True, False)
    assert k != SortKey("id", False, True)
    assert hash(SortKey("id", True, True)) == hash(SortKey("id", True, True))


def test_sortkey_refuses_bad_fields():
    refused(lambda: SortKey(""), ValueError, "SortKey.column must not be empty")
    refused(lambda: SortKey(3), TypeError, "SortKey.column must be a str, not int")
    refused(lambda: SortKey("id", 1), TypeError, "SortKey.descending must be a bool, not int")
    refused(
        lambda: SortKey("id", False, None),
        TypeError,
        "SortKey.nulls_first must be a bool, not NoneType",
    )


# ---------------------------------------------------------------------------
# Agg
# ---------------------------------------------------------------------------


def test_agg_arity_per_function_family():
    one = (col("score"),)
    two = (col("score"), col("id"))
    assert Agg("count").args == (), "count with no argument is count(*)"
    assert Agg("count", one).args == one
    assert Agg("sum", one).func == "sum"
    assert Agg("mean", one).k is None
    for func in ("corr", "covar_pop", "regr_slope", "regr_r2"):
        assert Agg(func, two).args == two, func
    assert Agg("largest_k", one, 3).k == 3


def test_agg_refuses_wrong_argument_counts():
    one = (col("score"),)
    two = (col("score"), col("id"))
    refused(lambda: Agg("sum"), ValueError, "Agg sum takes 1 argument(s), and was given 0")
    refused(lambda: Agg("sum", two), ValueError, "Agg sum takes 1 argument(s), and was given 2")
    refused(lambda: Agg("count", two), ValueError, "Agg count takes 0 or 1 argument(s), and was given 2")
    refused(lambda: Agg("corr", one), ValueError, "Agg corr takes 2 argument(s), and was given 1")
    refused(lambda: Agg("regr_count"), ValueError, "Agg regr_count takes 2 argument(s), and was given 0")
    refused(lambda: Agg("largest_k", (), 2), ValueError, "Agg largest_k takes 1 argument(s), and was given 0")


def test_agg_k_rules():
    one = (col("score"),)
    refused(lambda: Agg("largest_k", one), ValueError, "Agg largest_k needs k")
    refused(lambda: Agg("largest_k", one, 0), ValueError, "Agg.k must be at least 1")
    refused(lambda: Agg("largest_k", one, True), TypeError, "Agg.k must be an int, not bool")
    refused(lambda: Agg("largest_k", one, 2.0), TypeError, "Agg.k must be an int, not float")
    refused(lambda: Agg("sum", one, 2), ValueError, "Agg sum takes no k")


def test_agg_refuses_unknown_function_and_bad_args():
    listed = ", ".join(sorted(AGG_FUNCS))
    refused(lambda: Agg("total", (col("a"),)), ValueError, f"Agg op 'total' is not one of: {listed}")
    refused(lambda: Agg("udf", (col("a"),)), ValueError, f"Agg op 'udf' is not one of: {listed}")
    refused(lambda: Agg(3, (col("a"),)), TypeError, "Agg op must be a str, not int")
    refused(lambda: Agg("sum", [col("a")]), TypeError, "Agg.args must be a tuple, not list")
    refused(
        lambda: Agg("sum", ("a",)),
        TypeError,
        "Agg.args must be an expression node, not str",
    )
    refused(
        lambda: Agg("sum", (Agg("sum", (col("a"),)),)),
        TypeError,
        "Agg.args must be an expression node, not Agg",
    )
    window = WindowExpr("sum", "a")
    refused(
        lambda: Agg("sum", (window,)),
        TypeError,
        "Agg.args must be an expression node, not WindowExpr",
    )


def test_agg_equality_and_hash_are_structural():
    a = Agg("sum", (col("score"),))
    assert a == Agg("sum", (col("score"),))
    assert hash(a) == hash(Agg("sum", (col("score"),)))
    assert a != Agg("mean", (col("score"),))
    assert a != Agg("sum", (col("id"),))
    assert Agg("largest_k", (col("score"),), 2) != Agg("largest_k", (col("score"),), 3)


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------


def test_frame_accepts_every_unit_and_valid_bound_pair():
    f = Frame("rows", "preceding", "following", 2, 3)
    assert (f.units, f.start, f.end, f.start_offset, f.end_offset) == (
        "rows",
        "preceding",
        "following",
        2,
        3,
    )
    d = Frame("range", "unbounded_preceding", "current_row")
    assert (d.start_offset, d.end_offset) == (0, 0), "offsets default to 0"
    assert Frame("rows", "current_row", "unbounded_following").end == "unbounded_following"
    assert f == Frame("rows", "preceding", "following", 2, 3)
    assert hash(f) == hash(Frame("rows", "preceding", "following", 2, 3))
    assert f != Frame("rows", "preceding", "following", 2, 4)


def test_frame_refuses_bad_units_bounds_and_offsets():
    refused(
        lambda: Frame("groups", "current_row", "current_row"),
        ValueError,
        "Frame units op 'groups' is not one of: range, rows",
    )
    refused(
        lambda: Frame("rows", "middle", "current_row"),
        ValueError,
        "Frame start op 'middle' is not one of: current_row, following, preceding, "
        "unbounded_following, unbounded_preceding",
    )
    refused(
        lambda: Frame("rows", "current_row", "middle"),
        ValueError,
        "Frame end op 'middle' is not one of: current_row, following, preceding, "
        "unbounded_following, unbounded_preceding",
    )
    refused(
        lambda: Frame("rows", "unbounded_following", "unbounded_following"),
        ValueError,
        "Frame start cannot be unbounded_following",
    )
    refused(
        lambda: Frame("rows", "unbounded_preceding", "unbounded_preceding"),
        ValueError,
        "Frame end cannot be unbounded_preceding",
    )
    refused(
        lambda: Frame("rows", "preceding", "current_row", -1),
        ValueError,
        "Frame.start_offset must be at least 0",
    )
    refused(
        lambda: Frame("rows", "current_row", "following", 0, -2),
        ValueError,
        "Frame.end_offset must be at least 0",
    )
    refused(
        lambda: Frame("rows", "preceding", "current_row", True),
        TypeError,
        "Frame.start_offset must be an int, not bool",
    )
    refused(
        lambda: Frame("rows", "current_row", "following", 0, 1.5),
        TypeError,
        "Frame.end_offset must be an int, not float",
    )
    refused(lambda: Frame(1, "current_row", "current_row"), TypeError, "Frame units op must be a str, not int")


# ---------------------------------------------------------------------------
# WindowExpr
# ---------------------------------------------------------------------------


def test_window_ranking_functions_take_no_argument_and_need_order():
    order = (SortKey("score", True),)
    for func in ("row_number", "rank", "dense_rank", "percent_rank", "cume_dist"):
        w = WindowExpr(func, order_by=order)
        assert (w.arg, w.offset, w.partition_by, w.frame) == (None, 0, (), None), func
    assert WindowExpr("ntile", offset=4, order_by=order).offset == 4
    refused(
        lambda: WindowExpr("row_number"),
        ValueError,
        "WindowExpr row_number needs an order_by",
    )
    refused(lambda: WindowExpr("rank", order_by=()), ValueError, "WindowExpr rank needs an order_by")
    refused(
        lambda: WindowExpr("ntile", offset=2),
        ValueError,
        "WindowExpr ntile needs an order_by",
    )
    refused(
        lambda: WindowExpr("rank", "score", order_by=order),
        ValueError,
        "WindowExpr rank takes no argument column",
    )


def test_window_offset_rules_per_function():
    order = (SortKey("id"),)
    assert WindowExpr("lag", "score", 0, order_by=order).offset == 0, "lag offset 0 is allowed"
    assert WindowExpr("lead", "score", 2, order_by=order).offset == 2
    assert WindowExpr("nth_value", "score", 1).offset == 1
    assert WindowExpr("sum", "score").offset == 0
    for func in ("sum", "avg", "min", "max"):
        assert WindowExpr(func, "score", 3).offset == 3, func
    refused(
        lambda: WindowExpr("ntile", offset=0, order_by=order),
        ValueError,
        "WindowExpr.offset must be at least 1",
    )
    refused(
        lambda: WindowExpr("nth_value", "score", 0),
        ValueError,
        "WindowExpr.offset must be at least 1",
    )
    refused(
        lambda: WindowExpr("lag", "score", -1, order_by=order),
        ValueError,
        "WindowExpr.offset must be at least 0",
    )
    refused(
        lambda: WindowExpr("sum", "score", -1),
        ValueError,
        "WindowExpr.offset must be at least 0",
    )
    refused(
        lambda: WindowExpr("count", "score", 1),
        ValueError,
        "WindowExpr count takes no offset",
    )
    refused(
        lambda: WindowExpr("last_value", "score", 1),
        ValueError,
        "WindowExpr last_value takes no offset",
    )
    refused(
        lambda: WindowExpr("first_value", "score", 3),
        ValueError,
        "WindowExpr first_value takes no offset",
    )
    refused(
        lambda: WindowExpr("lag", "score", True, order_by=order),
        TypeError,
        "WindowExpr.offset must be an int, not bool",
    )


def test_window_argument_column_rules():
    order = (SortKey("id"),)
    for func in ("first_value", "last_value", "nth_value", "sum", "avg", "count", "min", "max"):
        offset = 1 if func == "nth_value" else 0
        assert WindowExpr(func, "score", offset).arg == "score", func
    refused(lambda: WindowExpr("sum"), ValueError, "WindowExpr sum needs an argument column")
    refused(
        lambda: WindowExpr("lag", order_by=order),
        ValueError,
        "WindowExpr lag needs an argument column",
    )
    refused(lambda: WindowExpr("sum", ""), ValueError, "WindowExpr.arg must not be empty")
    refused(lambda: WindowExpr("sum", 4), TypeError, "WindowExpr.arg must be a str, not int")


def test_window_refuses_unknown_function_and_bad_collections():
    listed = ", ".join(sorted(WINDOW_FUNCS))
    refused(lambda: WindowExpr("median", "a"), ValueError, f"WindowExpr op 'median' is not one of: {listed}")
    refused(lambda: WindowExpr(None, "a"), TypeError, "WindowExpr op must be a str, not NoneType")
    refused(
        lambda: WindowExpr("sum", "a", partition_by=["id"]),
        TypeError,
        "WindowExpr.partition_by must be a tuple, not list",
    )
    refused(
        lambda: WindowExpr("sum", "a", partition_by=("",)),
        ValueError,
        "WindowExpr.partition_by must not be empty",
    )
    refused(
        lambda: WindowExpr("sum", "a", partition_by=(1,)),
        TypeError,
        "WindowExpr.partition_by must be a str, not int",
    )
    refused(
        lambda: WindowExpr("sum", "a", order_by=[SortKey("id")]),
        TypeError,
        "WindowExpr.order_by must be a tuple, not list",
    )
    refused(
        lambda: WindowExpr("sum", "a", order_by=("id",)),
        TypeError,
        "WindowExpr.order_by must hold SortKey values, not str",
    )
    refused(
        lambda: WindowExpr("sum", "a", frame="rows"),
        TypeError,
        "WindowExpr.frame must be a Frame, not str",
    )


def test_window_carries_partition_order_and_frame_unchanged():
    frame = Frame("rows", "unbounded_preceding", "current_row")
    w = WindowExpr(
        "sum", "score", partition_by=("name",), order_by=(SortKey("id", True, True),), frame=frame
    )
    assert w.partition_by == ("name",)
    assert w.order_by == (SortKey("id", True, True),)
    assert w.frame is frame
    assert w == WindowExpr(
        "sum", "score", partition_by=("name",), order_by=(SortKey("id", True, True),), frame=frame
    )
    assert w != WindowExpr("sum", "score", partition_by=("name",), order_by=(SortKey("id"),), frame=frame)
    assert hash(w) == hash(
        WindowExpr(
            "sum", "score", partition_by=("name",), order_by=(SortKey("id", True, True),), frame=frame
        )
    )


# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------


def test_scan_columns_are_the_schema_names_in_order():
    s = people()
    assert s.columns == ("id", "name", "score"), s.columns
    assert s.schema[0] == Field("id", "int64"), "dtype tokens are carried unchanged"
    for fmt in ("parquet", "csv", "ndjson", "json", "orc", "avro", "arrow"):
        assert Scan("x", fmt, (Field("a", "int64"),)).format == fmt, fmt


def test_scan_equality_hash_and_repr_leave_out_derived_columns():
    assert people() == people()
    assert hash(people()) == hash(people())
    assert people() != cities()
    assert Scan("a", "csv", (Field("x", "int64"),)) != Scan("a", "json", (Field("x", "int64"),))
    assert repr(Scan("a", "csv", (Field("x", "int64"),))) == (
        "Scan(path='a', format='csv', schema=(Field(name='x', dtype='int64'),))"
    )


def test_scan_refuses_bad_fields():
    f = (Field("a", "int64"),)
    refused(lambda: Scan("", "parquet", f), ValueError, "Scan.path must not be empty")
    refused(lambda: Scan(3, "parquet", f), TypeError, "Scan.path must be a str, not int")
    refused(
        lambda: Scan("x", "xlsx", f),
        ValueError,
        "Scan format op 'xlsx' is not one of: arrow, avro, csv, json, ndjson, orc, parquet",
    )
    refused(lambda: Scan("x", None, f), TypeError, "Scan format op must be a str, not NoneType")
    refused(lambda: Scan("x", "csv", ()), ValueError, "Scan.schema must not be empty")
    refused(lambda: Scan("x", "csv", [Field("a", "int64")]), TypeError, "Scan.schema must be a tuple, not list")
    refused(
        lambda: Scan("x", "csv", (("a", "int64"),)),
        TypeError,
        "Scan.schema must hold Field values, not tuple",
    )
    refused(
        lambda: Scan("x", "csv", (Field("a", "int64"), Field("b", "int64"), Field("a", "string"))),
        ValueError,
        "Scan: the output name 'a' appears more than once",
    )


# ---------------------------------------------------------------------------
# Filter
# ---------------------------------------------------------------------------


def test_filter_keeps_child_columns():
    f = Filter(people(), Compare("gt", col("score"), Lit(1.5)))
    assert f.columns == ("id", "name", "score"), f.columns
    assert f.child == people()
    assert f == Filter(people(), Compare("gt", col("score"), Lit(1.5)))
    assert hash(f) == hash(Filter(people(), Compare("gt", col("score"), Lit(1.5))))
    assert Filter(people(), Lit(True)).columns == ("id", "name", "score"), "a constant predicate is a predicate"


def test_filter_refuses_non_predicates_aliases_and_wrong_types():
    refused(lambda: Filter(people(), col("id")), TypeError, "Filter needs a predicate, not a ColRef")
    refused(lambda: Filter(people(), Lit(3)), TypeError, "Filter needs a predicate, not a Lit")
    refused(
        lambda: Filter(people(), Alias(Compare("eq", col("id"), Lit(1)), "p")),
        ValueError,
        "Filter.predicate must not be an Alias",
    )
    refused(
        lambda: Filter(people(), "id > 1"),
        TypeError,
        "Filter.predicate must be an expression node, not str",
    )
    refused(
        lambda: Filter("people", Lit(True)),
        TypeError,
        "Filter.child must be a plan node, not str",
    )


def test_filter_refuses_unknown_and_sided_columns():
    refused(
        lambda: Filter(people(), Compare("eq", col("zzz"), Lit(1))),
        KeyError,
        missing("zzz"),
    )
    refused(
        lambda: Filter(people(), Compare("eq", col("scor"), Lit(1))),
        KeyError,
        missing("scor", "score"),
    )
    nested = Unary("not", Compare("eq", Lit(1), col("nme")))
    refused(lambda: Filter(people(), nested), KeyError, missing("nme", "name"))
    refused(
        lambda: Filter(people(), Compare("eq", col("id", "left"), Lit(1))),
        ValueError,
        "Filter: the column 'id' has a side, which only a join residual may carry",
    )


# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------


def test_project_columns_are_the_item_names_in_order():
    p = Project(people(), (("n", col("name")), ("i", col("id")), ("one", Lit(1))))
    assert p.columns == ("n", "i", "one"), p.columns
    assert Project(people(), (ident("id"),)).columns == ("id",)
    assert p == Project(people(), (("n", col("name")), ("i", col("id")), ("one", Lit(1))))
    assert hash(p) == hash(Project(people(), (("n", col("name")), ("i", col("id")), ("one", Lit(1)))))
    assert p != Project(people(), (("i", col("id")), ("n", col("name")), ("one", Lit(1)))), "order is identity"


def test_project_accepts_window_items_and_checks_their_columns():
    w = WindowExpr("rank", partition_by=("name",), order_by=(SortKey("score", True),))
    p = Project(people(), (ident("id"), ("r", w)))
    assert p.columns == ("id", "r"), p.columns
    refused(
        lambda: Project(people(), (("s", WindowExpr("sum", "scor")),)),
        KeyError,
        missing("scor", "score"),
    )
    refused(
        lambda: Project(people(), (("s", WindowExpr("sum", "score", partition_by=("zzz",))),)),
        KeyError,
        missing("zzz"),
    )
    refused(
        lambda: Project(people(), (("r", WindowExpr("rank", order_by=(SortKey("zzz"),))),)),
        KeyError,
        missing("zzz"),
    )


def test_project_refuses_malformed_items():
    refused(lambda: Project(people(), ()), ValueError, "Project.items must not be empty")
    refused(lambda: Project(people(), [ident("id")]), TypeError, "Project.items must be a tuple, not list")
    refused(
        lambda: Project(people(), ("id",)),
        TypeError,
        "Project.items must hold (name, expression) pairs",
    )
    refused(
        lambda: Project(people(), (("a", col("id"), 1),)),
        TypeError,
        "Project.items must hold (name, expression) pairs",
    )
    refused(lambda: Project(people(), (("", col("id")),)), ValueError, "Project.item name must not be empty")
    refused(
        lambda: Project(people(), ((1, col("id")),)),
        TypeError,
        "Project.item name must be a str, not int",
    )
    refused(
        lambda: Project(people(), (("a", "id"),)),
        TypeError,
        "Project.items must be an expression node, not str",
    )
    refused(
        lambda: Project(people(), (("a", Alias(col("id"), "b")),)),
        ValueError,
        "Project item 'a' must not be an Alias at the root; the item names it",
    )
    refused(
        lambda: Project(people(), (ident("id"), ("id", col("name")))),
        ValueError,
        "Project: the output name 'id' appears more than once",
    )
    refused(lambda: Project("people", (ident("id"),)), TypeError, "Project.child must be a plan node, not str")


def test_project_refuses_unknown_and_sided_columns():
    refused(lambda: Project(people(), (("a", col("zzz")),)), KeyError, missing("zzz"))
    refused(lambda: Project(people(), (("a", col("idd")),)), KeyError, missing("idd", "id"))
    refused(
        lambda: Project(people(), (("a", col("id", "right")),)),
        ValueError,
        "Project: the column 'id' has a side, which only a join residual may carry",
    )


# ---------------------------------------------------------------------------
# Aggregate
# ---------------------------------------------------------------------------


def test_aggregate_columns_are_keys_then_aggregate_names():
    a = Aggregate(
        people(),
        ("name",),
        (("total", Agg("sum", (col("score"),))), ("n", Agg("count"))),
    )
    assert a.columns == ("name", "total", "n"), a.columns
    assert a == Aggregate(
        people(), ("name",), (("total", Agg("sum", (col("score"),))), ("n", Agg("count")))
    )
    assert hash(a) == hash(
        Aggregate(people(), ("name",), (("total", Agg("sum", (col("score"),))), ("n", Agg("count"))))
    )


def test_aggregate_without_keys_is_a_whole_frame_aggregate():
    a = Aggregate(people(), (), (("n", Agg("count")),))
    assert a.columns == ("n",), a.columns
    assert Aggregate(people(), ("id", "name"), ()).columns == ("id", "name"), "keys alone are allowed"
    two = Aggregate(people(), (), (("c", Agg("corr", (col("id"), col("score")))),))
    assert two.columns == ("c",)


def test_aggregate_refuses_malformed_input():
    refused(
        lambda: Aggregate(people(), (), ()),
        ValueError,
        "Aggregate needs at least one key or one aggregate",
    )
    refused(
        lambda: Aggregate(people(), ["id"], ()),
        TypeError,
        "Aggregate.keys must be a tuple, not list",
    )
    refused(
        lambda: Aggregate(people(), ("id",), [("n", Agg("count"))]),
        TypeError,
        "Aggregate.aggs must be a tuple, not list",
    )
    refused(
        lambda: Aggregate(people(), (), ("n",)),
        TypeError,
        "Aggregate.aggs must hold (name, Agg) pairs",
    )
    refused(
        lambda: Aggregate(people(), (), (("n", "count"),)),
        TypeError,
        "Aggregate.aggs must hold Agg values, not str",
    )
    refused(
        lambda: Aggregate(people(), (), (("", Agg("count")),)),
        ValueError,
        "Aggregate.agg name must not be empty",
    )
    refused(
        lambda: Aggregate(people(), ("",), ()),
        ValueError,
        "Aggregate.keys must not be empty",
    )
    refused(
        lambda: Aggregate("people", ("id",), ()),
        TypeError,
        "Aggregate.child must be a plan node, not str",
    )


def test_aggregate_refuses_duplicate_output_names():
    refused(
        lambda: Aggregate(people(), ("id", "id"), ()),
        ValueError,
        "Aggregate: the output name 'id' appears more than once",
    )
    refused(
        lambda: Aggregate(people(), ("id",), (("id", Agg("count")),)),
        ValueError,
        "Aggregate: the output name 'id' appears more than once",
    )
    refused(
        lambda: Aggregate(people(), (), (("n", Agg("count")), ("n", Agg("sum", (col("id"),))))),
        ValueError,
        "Aggregate: the output name 'n' appears more than once",
    )


def test_aggregate_refuses_unknown_and_sided_columns():
    refused(lambda: Aggregate(people(), ("zzz",), ()), KeyError, missing("zzz"))
    refused(lambda: Aggregate(people(), ("nme",), ()), KeyError, missing("nme", "name"))
    refused(
        lambda: Aggregate(people(), (), (("t", Agg("sum", (col("scor"),))),)),
        KeyError,
        missing("scor", "score"),
    )
    refused(
        lambda: Aggregate(people(), (), (("t", Agg("corr", (col("id"), col("zzz")))),)),
        KeyError,
        missing("zzz"),
    )
    refused(
        lambda: Aggregate(people(), (), (("t", Agg("sum", (col("id", "left"),))),)),
        ValueError,
        "Aggregate: the column 'id' has a side, which only a join residual may carry",
    )


# ---------------------------------------------------------------------------
# Sort, TopN, Limit, Distinct
# ---------------------------------------------------------------------------


def test_sort_keeps_columns_and_orders_keys():
    s = Sort(people(), (SortKey("score", True), SortKey("id")))
    assert s.columns == ("id", "name", "score"), s.columns
    assert s.keys[0] == SortKey("score", True)
    assert s == Sort(people(), (SortKey("score", True), SortKey("id")))
    assert s != Sort(people(), (SortKey("id"), SortKey("score", True))), "key order is identity"
    assert hash(s) == hash(Sort(people(), (SortKey("score", True), SortKey("id"))))


def test_sort_refuses_empty_repeated_unknown_and_mistyped_keys():
    refused(lambda: Sort(people(), ()), ValueError, "Sort.keys must not be empty")
    refused(lambda: Sort(people(), [SortKey("id")]), TypeError, "Sort.keys must be a tuple, not list")
    refused(lambda: Sort(people(), ("id",)), TypeError, "Sort.keys must hold SortKey values, not str")
    refused(
        lambda: Sort(people(), (SortKey("id"), SortKey("id", True))),
        ValueError,
        "Sort: the column 'id' is a key more than once",
    )
    refused(lambda: Sort(people(), (SortKey("zzz"),)), KeyError, missing("zzz"))
    refused(lambda: Sort(people(), (SortKey("idd"),)), KeyError, missing("idd", "id"))
    refused(lambda: Sort("people", (SortKey("id"),)), TypeError, "Sort.child must be a plan node, not str")


def test_topn_keeps_columns_and_checks_n_and_keys():
    t = TopN(people(), (SortKey("score", True),), 5)
    assert t.columns == ("id", "name", "score"), t.columns
    assert t.n == 5
    assert TopN(people(), (SortKey("id"),), 0).n == 0, "zero is a valid count"
    assert t == TopN(people(), (SortKey("score", True),), 5)
    assert t != TopN(people(), (SortKey("score", True),), 6)
    refused(lambda: TopN(people(), (SortKey("id"),), -1), ValueError, "TopN.n must be at least 0")
    refused(lambda: TopN(people(), (SortKey("id"),), True), TypeError, "TopN.n must be an int, not bool")
    refused(lambda: TopN(people(), (SortKey("id"),), "3"), TypeError, "TopN.n must be an int, not str")
    refused(lambda: TopN(people(), (), 3), ValueError, "TopN.keys must not be empty")
    refused(
        lambda: TopN(people(), (SortKey("id"), SortKey("id")), 3),
        ValueError,
        "TopN: the column 'id' is a key more than once",
    )
    refused(lambda: TopN(people(), (SortKey("zzz"),), 3), KeyError, missing("zzz"))
    refused(lambda: TopN("people", (SortKey("id"),), 3), TypeError, "TopN.child must be a plan node, not str")


def test_limit_keeps_columns_and_checks_n_and_offset():
    lim = Limit(people(), 10)
    assert lim.columns == ("id", "name", "score"), lim.columns
    assert (lim.n, lim.offset) == (10, 0), "offset defaults to 0"
    assert Limit(people(), 0, 0).n == 0
    assert Limit(people(), 5, 2) == Limit(people(), 5, 2)
    assert Limit(people(), 5, 2) != Limit(people(), 5, 3)
    assert hash(Limit(people(), 5, 2)) == hash(Limit(people(), 5, 2))
    refused(lambda: Limit(people(), -1), ValueError, "Limit.n must be at least 0")
    refused(lambda: Limit(people(), 1, -1), ValueError, "Limit.offset must be at least 0")
    refused(lambda: Limit(people(), True), TypeError, "Limit.n must be an int, not bool")
    refused(lambda: Limit(people(), 1, False), TypeError, "Limit.offset must be an int, not bool")
    refused(lambda: Limit(people(), 1.0), TypeError, "Limit.n must be an int, not float")
    refused(lambda: Limit(None, 1), TypeError, "Limit.child must be a plan node, not NoneType")


def test_distinct_over_all_columns_or_a_subset():
    d = Distinct(people())
    assert d.subset is None
    assert d.columns == ("id", "name", "score"), d.columns
    s = Distinct(people(), ("name",))
    assert s.columns == ("id", "name", "score"), "a subset does not narrow the output"
    assert s.subset == ("name",)
    assert d != s
    assert s == Distinct(people(), ("name",))
    assert hash(s) == hash(Distinct(people(), ("name",)))


def test_distinct_refuses_bad_subsets():
    refused(lambda: Distinct(people(), ()), ValueError, "Distinct.subset must not be empty")
    refused(lambda: Distinct(people(), ["id"]), TypeError, "Distinct.subset must be a tuple, not list")
    refused(
        lambda: Distinct(people(), ("id", "id")),
        ValueError,
        "Distinct: the output name 'id' appears more than once",
    )
    refused(lambda: Distinct(people(), ("zzz",)), KeyError, missing("zzz"))
    refused(lambda: Distinct(people(), ("id", "nam")), KeyError, missing("nam", "name"))
    refused(lambda: Distinct(people(), (3,)), TypeError, "Distinct.subset must be a str, not int")
    refused(lambda: Distinct("people"), TypeError, "Distinct.child must be a plan node, not str")


def test_unnest_keeps_the_childs_columns_and_walks_to_its_child():
    base = people()
    node = Unnest(base, "name", True)
    assert node.columns == ("id", "name", "score"), node.columns
    assert node.child is base and node.column == "name" and node.keep_empty is True
    assert node == Unnest(people(), "name", True) and hash(node) == hash(Unnest(people(), "name", True))
    assert node != Unnest(people(), "name", False)
    assert node != Unnest(people(), "id", True)
    assert unnest(base, "name", False) == Unnest(base, "name", False)
    assert list(walk_plan(node)) == [node, base]


def test_unnest_refuses_bad_arguments():
    refused(lambda: Unnest(people(), "zzz", True), KeyError, missing("zzz"))
    refused(lambda: Unnest(people(), "nam", True), KeyError, missing("nam", "name"))
    refused(lambda: Unnest(people(), 3, True), TypeError, "Unnest.column must be a str, not int")
    refused(lambda: Unnest(people(), "", True), ValueError, "Unnest.column must not be empty")
    refused(lambda: Unnest(people(), "name", 1), TypeError, "Unnest.keep_empty must be a bool, not int")
    refused(lambda: Unnest("people", "name", True), TypeError, "Unnest.child must be a plan node, not str")
    refused(lambda: unnest("people", "name", True), TypeError, "unnest plan must be a plan node, not str")


def main():
    tests = [
        value
        for name, value in list(globals().items())
        if name.startswith("test_") and callable(value) and value.__module__ == __name__
    ]
    for test in tests:
        test()
    print(f"test_ops_rel: {len(tests)} tests passed")


if __name__ == "__main__":
    main()
