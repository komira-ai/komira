"""The verbs of komira._ops, one test per verb: the tree each builds equals a
hand-written tree, the cases that add no node return the plan itself, and
every refusal raises its exact class with its full message.

    test_ops_verbs.py
"""

from komira import _ops
from komira._ops import (
    Agg,
    Aggregate,
    BoolOp,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Join,
    Limit,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Unary,
    Union,
    Write,
    WriteTarget,
)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, repr(e)
    assert e.args[0] == message, repr(e.args[0])


FIELDS = (Field("a", "int64"), Field("b", "string"), Field("c", "double"))
T = Scan("t.parquet", "parquet", FIELDS)
U = Scan("u.parquet", "parquet", (Field("a", "int64"), Field("d", "string")))
GT = Compare("gt", ColRef("a"), Lit(1))
LT = Compare("lt", ColRef("c"), Lit(2.5))
KEY_A = SortKey("a")
KEY_B_DESC = SortKey("b", True, True)

NO_B = "no column named 'z' in this frame; the frame's columns are: a, b, c"
CLOSE_B = "no column named 'bb' in this frame; the closest is 'b'; the frame's columns are: a, b, c"


def test_scan_builds_a_scan_from_pairs_or_fields():
    assert _ops.scan("t.parquet", "parquet", [("a", "int64"), ("b", "string"), ("c", "double")]) == T
    assert _ops.scan("t.parquet", "parquet", FIELDS) == T
    assert _ops.scan("t.parquet", "parquet", list(FIELDS)) == T
    assert _ops.scan("t.parquet", "parquet", [["a", "int64"], Field("b", "string")]) == Scan(
        "t.parquet", "parquet", (Field("a", "int64"), Field("b", "string"))
    )
    assert _ops.scan("t.parquet", "parquet", FIELDS).columns == ("a", "b", "c")


def test_scan_refuses_a_bad_schema_path_or_format():
    refused(lambda: _ops.scan("t", "parquet", "ab"), TypeError, "scan schema must be a list or tuple, not str")
    refused(lambda: _ops.scan("t", "parquet", [3]), TypeError, "scan schema must hold Field values or (name, dtype) pairs")
    refused(lambda: _ops.scan("t", "parquet", [("a", "int64", 1)]), TypeError, "scan schema must hold Field values or (name, dtype) pairs")
    refused(lambda: _ops.scan("t", "parquet", []), ValueError, "Scan.schema must not be empty")
    refused(lambda: _ops.scan("t", "parquet", [("", "int64")]), ValueError, "Field.name must not be empty")
    refused(lambda: _ops.scan("t", "parquet", [("a", "")]), ValueError, "Field.dtype must not be empty")
    refused(
        lambda: _ops.scan("t", "parquet", [("a", "int64"), ("a", "string")]),
        ValueError,
        "Scan: the output name 'a' appears more than once",
    )
    refused(lambda: _ops.scan("", "parquet", FIELDS), ValueError, "Scan.path must not be empty")
    refused(
        lambda: _ops.scan("t", "xml", FIELDS),
        ValueError,
        "Scan format op 'xml' is not one of: arrow, avro, csv, json, ndjson, orc, parquet",
    )


def test_filter_builds_a_filter_over_the_plan():
    assert _ops.filter_(T, GT) == Filter(T, GT)
    assert _ops.filter_(T, GT).columns == ("a", "b", "c")
    both = BoolOp("and", GT, LT)
    assert _ops.filter_(_ops.filter_(T, GT), LT) == Filter(Filter(T, GT), LT)
    assert _ops.filter_(T, both) == Filter(T, both)


def test_filter_goes_below_a_sort():
    assert _ops.filter_(Sort(T, (KEY_A,)), GT) == Sort(Filter(T, GT), (KEY_A,))
    assert _ops.filter_(Sort(T, (KEY_A, KEY_B_DESC)), GT) == Sort(Filter(T, GT), (KEY_A, KEY_B_DESC))


def test_filter_stays_above_a_top_n():
    top = TopN(T, (KEY_A,), 5)
    assert _ops.filter_(top, GT) == Filter(top, GT)


def test_filter_stays_above_other_nodes():
    limited = Limit(T, 3)
    assert _ops.filter_(limited, GT) == Filter(limited, GT)
    projected = Project(T, (("a", ColRef("a")),))
    assert _ops.filter_(projected, GT) == Filter(projected, GT)


def test_filter_refuses_a_non_plan_a_non_predicate_or_an_unknown_column():
    refused(lambda: _ops.filter_(3, GT), TypeError, "filter plan must be a plan node, not int")
    refused(lambda: _ops.filter_(T, ColRef("a")), TypeError, "Filter needs a predicate, not a ColRef")
    refused(lambda: _ops.filter_(T, 3), TypeError, "Filter.predicate must be an expression node, not int")
    refused(lambda: _ops.filter_(T, Compare("eq", ColRef("bb"), Lit(1))), KeyError, CLOSE_B)
    refused(lambda: _ops.filter_(T, Compare("eq", ColRef("z"), Lit(1))), KeyError, NO_B)
    refused(
        lambda: _ops.filter_(T, Compare("eq", ColRef("a", "left"), Lit(1))),
        ValueError,
        "Filter: the column 'a' has a side, which only a join residual may carry",
    )


def test_filter_refuses_an_unknown_column_below_a_sort():
    refused(lambda: _ops.filter_(Sort(T, (KEY_A,)), Compare("eq", ColRef("z"), Lit(1))), KeyError, NO_B)


def test_select_builds_a_project_of_column_refs():
    assert _ops.select(T, ["b", "a"]) == Project(T, (("b", ColRef("b")), ("a", ColRef("a"))))
    assert _ops.select(T, ("c",)) == Project(T, (("c", ColRef("c")),))
    assert _ops.select(T, ["b", "a"]).columns == ("b", "a")
    assert _ops.select(T, ["a", "b"]) == Project(T, (("a", ColRef("a")), ("b", ColRef("b"))))


def test_select_goes_below_a_sort_that_keeps_its_keys():
    sorted_plan = Sort(T, (KEY_A, KEY_B_DESC))
    assert _ops.select(sorted_plan, ["b", "a"]) == Sort(
        Project(T, (("b", ColRef("b")), ("a", ColRef("a")))), (KEY_A, KEY_B_DESC)
    )
    assert _ops.select(sorted_plan, ["b", "a"]).columns == ("b", "a")


def test_select_stays_above_a_sort_that_loses_a_key_and_above_a_top_n_or_limit():
    sorted_plan = Sort(T, (KEY_A, KEY_B_DESC))
    assert _ops.select(sorted_plan, ["a", "c"]) == Project(sorted_plan, (("a", ColRef("a")), ("c", ColRef("c"))))
    top = TopN(T, (KEY_A,), 5)
    assert _ops.select(top, ["a", "b"]) == Project(top, (("a", ColRef("a")), ("b", ColRef("b"))))
    limited = Limit(Sort(T, (KEY_A,)), 5)
    assert _ops.select(limited, ["a", "b"]) == Project(limited, (("a", ColRef("a")), ("b", ColRef("b"))))


def test_select_of_every_column_in_order_adds_no_node():
    assert _ops.select(T, ["a", "b", "c"]) is T
    assert _ops.select(T, ("a", "b", "c")) is T
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.select(sorted_plan, ["a", "b", "c"]) is sorted_plan


def test_select_refuses_empty_unknown_repeated_or_mistyped_columns():
    refused(lambda: _ops.select(T, []), ValueError, "select needs at least one column")
    refused(lambda: _ops.select(T, ["a", "z"]), KeyError, NO_B)
    refused(lambda: _ops.select(T, ["bb"]), KeyError, CLOSE_B)
    refused(lambda: _ops.select(T, ["a", "a"]), ValueError, "Project: the output name 'a' appears more than once")
    refused(lambda: _ops.select(T, "abc"), TypeError, "select columns must be a list or tuple, not str")
    refused(lambda: _ops.select(T, ["a", 1]), TypeError, "select columns must hold str values, not int")
    refused(lambda: _ops.select(3, ["a"]), TypeError, "select plan must be a plan node, not int")


def test_with_columns_replaces_in_place_and_appends_the_rest():
    double = _ops.Arith("mul", ColRef("a"), Lit(2))
    total = _ops.Arith("add", ColRef("a"), ColRef("c"))
    assert _ops.with_columns(T, [("a", double), ("e", total)]) == Project(
        T, (("a", double), ("b", ColRef("b")), ("c", ColRef("c")), ("e", total))
    )
    assert _ops.with_columns(T, [("e", total)]) == Project(
        T, (("a", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")), ("e", total))
    )
    assert _ops.with_columns(T, [("e", total)]).columns == ("a", "b", "c", "e")


def test_with_columns_appends_new_columns_in_the_order_given():
    one, two = Lit(1), Lit(2)
    assert _ops.with_columns(T, (("y", one), ("x", two))) == Project(
        T, (("a", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")), ("y", one), ("x", two))
    )


def test_with_columns_goes_below_a_sort_whose_keys_it_keeps():
    total = _ops.Arith("add", ColRef("a"), ColRef("c"))
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.with_columns(sorted_plan, [("c", total), ("e", Lit(1))]) == Sort(
        Project(T, (("a", ColRef("a")), ("b", ColRef("b")), ("c", total), ("e", Lit(1)))), (KEY_A,)
    )
    assert _ops.with_columns(sorted_plan, [("a", ColRef("a"))]) == Sort(
        Project(T, (("a", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")))), (KEY_A,)
    )


def test_with_columns_stays_above_a_sort_whose_key_it_replaces_and_above_a_top_n_or_limit():
    double = _ops.Arith("mul", ColRef("a"), Lit(2))
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.with_columns(sorted_plan, [("a", double)]) == Project(
        sorted_plan, (("a", double), ("b", ColRef("b")), ("c", ColRef("c")))
    )
    top = TopN(T, (KEY_A,), 5)
    assert _ops.with_columns(top, [("e", Lit(1))]) == Project(
        top, (("a", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")), ("e", Lit(1)))
    )
    limited = Limit(sorted_plan, 5)
    assert _ops.with_columns(limited, [("e", Lit(1))]) == Project(
        limited, (("a", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")), ("e", Lit(1)))
    )


def test_with_columns_of_nothing_adds_no_node():
    assert _ops.with_columns(T, []) is T
    assert _ops.with_columns(T, ()) is T
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.with_columns(sorted_plan, []) is sorted_plan


def test_with_columns_refuses_repeats_bad_items_and_unknown_columns():
    refused(
        lambda: _ops.with_columns(T, [("x", Lit(1)), ("x", Lit(2))]),
        ValueError,
        "with_columns: the output name 'x' is produced by more than one expression",
    )
    refused(lambda: _ops.with_columns(T, [("x", ColRef("z"))]), KeyError, NO_B)
    refused(lambda: _ops.with_columns(T, [("", Lit(1))]), ValueError, "Project.item name must not be empty")
    refused(lambda: _ops.with_columns(T, ["x"]), TypeError, "with_columns items must hold (name, value) pairs")
    refused(lambda: _ops.with_columns(T, [(1, Lit(1))]), TypeError, "with_columns items names must be str, not int")
    refused(lambda: _ops.with_columns(T, {"x": Lit(1)}), TypeError, "with_columns items must be a list or tuple, not dict")
    refused(lambda: _ops.with_columns(T, [("x", 1)]), TypeError, "Project.items must be an expression node, not int")
    refused(
        lambda: _ops.with_columns(T, [("x", _ops.Alias(Lit(1), "y"))]),
        ValueError,
        "Project item 'x' must not be an Alias at the root; the item names it",
    )
    refused(lambda: _ops.with_columns(3, [("x", Lit(1))]), TypeError, "with_columns plan must be a plan node, not int")


def test_rename_builds_a_project_of_every_column():
    assert _ops.rename(T, {"a": "x"}) == Project(T, (("x", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c"))))
    assert _ops.rename(T, {"c": "z", "a": "y"}) == Project(
        T, (("y", ColRef("a")), ("b", ColRef("b")), ("z", ColRef("c")))
    )
    assert _ops.rename(T, {"a": "x"}).columns == ("x", "b", "c")


def test_rename_goes_below_a_sort_whose_keys_keep_their_names():
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.rename(sorted_plan, {"b": "x"}) == Sort(
        Project(T, (("a", ColRef("a")), ("x", ColRef("b")), ("c", ColRef("c")))), (KEY_A,)
    )
    assert _ops.rename(sorted_plan, {"b": "x"}).columns == ("a", "x", "c")


def test_rename_stays_above_a_sort_whose_key_it_renames_and_above_a_top_n_or_limit():
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.rename(sorted_plan, {"a": "x"}) == Project(
        sorted_plan, (("x", ColRef("a")), ("b", ColRef("b")), ("c", ColRef("c")))
    )
    top = TopN(T, (KEY_A,), 5)
    assert _ops.rename(top, {"b": "x"}) == Project(
        top, (("a", ColRef("a")), ("x", ColRef("b")), ("c", ColRef("c")))
    )
    limited = Limit(sorted_plan, 5)
    assert _ops.rename(limited, {"b": "x"}) == Project(
        limited, (("a", ColRef("a")), ("x", ColRef("b")), ("c", ColRef("c")))
    )


def test_rename_swaps_two_columns():
    assert _ops.rename(T, {"a": "b", "b": "a"}) == Project(
        T, (("b", ColRef("a")), ("a", ColRef("b")), ("c", ColRef("c")))
    )


def test_rename_that_changes_no_name_adds_no_node():
    assert _ops.rename(T, {}) is T
    assert _ops.rename(T, {"a": "a"}) is T
    assert _ops.rename(T, {"a": "a", "b": "b"}) is T
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.rename(sorted_plan, {"a": "a"}) is sorted_plan


def test_rename_refuses_unknown_columns_collisions_and_bad_types():
    refused(lambda: _ops.rename(T, {"z": "x"}), KeyError, NO_B)
    refused(lambda: _ops.rename(T, {"bb": "x"}), KeyError, CLOSE_B)
    refused(lambda: _ops.rename(T, {"a": "b"}), ValueError, "rename: the column 'b' would appear twice")
    refused(lambda: _ops.rename(T, {"a": "x", "b": "x"}), ValueError, "rename: the column 'x' would appear twice")
    refused(lambda: _ops.rename(T, [("a", "x")]), TypeError, "rename mapping must be a dict, not list")
    refused(lambda: _ops.rename(T, {"a": 1}), TypeError, "rename mapping must map str to str")
    refused(lambda: _ops.rename(T, {1: "a"}), TypeError, "rename mapping must map str to str")
    refused(lambda: _ops.rename(T, {"a": ""}), ValueError, "Project.item name must not be empty")
    refused(lambda: _ops.rename(3, {"a": "x"}), TypeError, "rename plan must be a plan node, not int")


def test_drop_nulls_filters_on_every_column_by_default():
    expected = Filter(
        T,
        BoolOp(
            "and",
            BoolOp("and", Unary("is_not_null", ColRef("a")), Unary("is_not_null", ColRef("b"))),
            Unary("is_not_null", ColRef("c")),
        ),
    )
    assert _ops.drop_nulls(T) == expected
    assert _ops.drop_nulls(T, None) == expected
    assert _ops.drop_nulls(T).columns == ("a", "b", "c")


def test_drop_nulls_goes_below_a_sort_and_stays_above_a_top_n():
    keep = Unary("is_not_null", ColRef("b"))
    assert _ops.drop_nulls(Sort(T, (KEY_A,)), ["b"]) == Sort(Filter(T, keep), (KEY_A,))
    top = TopN(T, (KEY_A,), 5)
    assert _ops.drop_nulls(top, ["b"]) == Filter(top, keep)


def test_drop_nulls_filters_on_the_subset_in_the_order_given():
    assert _ops.drop_nulls(T, ["c", "a"]) == Filter(
        T, BoolOp("and", Unary("is_not_null", ColRef("c")), Unary("is_not_null", ColRef("a")))
    )
    assert _ops.drop_nulls(T, ("b",)) == Filter(T, Unary("is_not_null", ColRef("b")))


def test_drop_nulls_of_an_empty_subset_adds_no_node():
    assert _ops.drop_nulls(T, []) is T
    assert _ops.drop_nulls(T, ()) is T


def test_drop_nulls_refuses_unknown_columns_and_bad_types():
    refused(lambda: _ops.drop_nulls(T, ["a", "z"]), KeyError, NO_B)
    refused(lambda: _ops.drop_nulls(T, "a"), TypeError, "drop_nulls subset must be a list or tuple, not str")
    refused(lambda: _ops.drop_nulls(T, [1]), TypeError, "drop_nulls subset must hold str values, not int")
    refused(lambda: _ops.drop_nulls(3), TypeError, "drop_nulls plan must be a plan node, not int")


def test_sort_builds_a_sort_over_the_plan():
    assert _ops.sort(T, [KEY_A, KEY_B_DESC]) == Sort(T, (KEY_A, KEY_B_DESC))
    assert _ops.sort(T, (KEY_A,)) == Sort(T, (KEY_A,))
    assert _ops.sort(T, (KEY_A,)).columns == ("a", "b", "c")


def test_sort_over_a_sort_replaces_the_inner_sort():
    inner = Sort(T, (KEY_A,))
    assert _ops.sort(inner, [KEY_B_DESC]) == Sort(T, (KEY_B_DESC,))
    assert _ops.sort(_ops.sort(inner, [KEY_B_DESC]), [SortKey("c")]) == Sort(T, (SortKey("c"),))
    over_filter = Sort(Filter(T, GT), (KEY_A,))
    assert _ops.sort(over_filter, [KEY_B_DESC]) == Sort(Filter(T, GT), (KEY_B_DESC,))


def test_sort_refuses_empty_repeated_unknown_or_mistyped_keys():
    refused(lambda: _ops.sort(T, []), ValueError, "Sort.keys must not be empty")
    refused(lambda: _ops.sort(T, [KEY_A, SortKey("a", True)]), ValueError, "Sort: the column 'a' is a key more than once")
    refused(lambda: _ops.sort(T, [SortKey("z")]), KeyError, NO_B)
    refused(lambda: _ops.sort(T, ["a"]), TypeError, "sort keys must hold SortKey values, not str")
    refused(lambda: _ops.sort(T, KEY_A), TypeError, "sort keys must be a list or tuple, not SortKey")
    refused(lambda: _ops.sort(3, [KEY_A]), TypeError, "sort plan must be a plan node, not int")
    refused(lambda: _ops.sort(Sort(T, (KEY_A,)), [SortKey("z")]), KeyError, NO_B)


def test_limit_builds_a_limit_with_its_offset():
    assert _ops.limit(T, 5) == Limit(T, 5, 0)
    assert _ops.limit(T, 5, 2) == Limit(T, 5, 2)
    assert _ops.limit(T, 0) == Limit(T, 0)
    assert _ops.limit(T, 5, 2).columns == ("a", "b", "c")


def test_limit_over_a_sort_keeps_the_limit_above_it():
    sorted_plan = Sort(T, (KEY_A,))
    assert _ops.limit(sorted_plan, 3) == Limit(sorted_plan, 3)


def test_limit_refuses_negative_mistyped_counts_and_non_plans():
    refused(lambda: _ops.limit(T, -1), ValueError, "Limit.n must be at least 0")
    refused(lambda: _ops.limit(T, 1, -1), ValueError, "Limit.offset must be at least 0")
    refused(lambda: _ops.limit(T, True), TypeError, "Limit.n must be an int, not bool")
    refused(lambda: _ops.limit(T, 1.5), TypeError, "Limit.n must be an int, not float")
    refused(lambda: _ops.limit(T, 1, "0"), TypeError, "Limit.offset must be an int, not str")
    refused(lambda: _ops.limit("t", 1), TypeError, "limit plan must be a plan node, not str")


def test_top_n_builds_a_top_n():
    assert _ops.top_n(T, [KEY_A, KEY_B_DESC], 3) == TopN(T, (KEY_A, KEY_B_DESC), 3)
    assert _ops.top_n(T, (KEY_A,), 0) == TopN(T, (KEY_A,), 0)
    assert _ops.top_n(T, (KEY_A,), 3).columns == ("a", "b", "c")


def test_top_n_refuses_bad_keys_counts_and_non_plans():
    refused(lambda: _ops.top_n(T, [], 3), ValueError, "TopN.keys must not be empty")
    refused(lambda: _ops.top_n(T, [KEY_A, KEY_A], 3), ValueError, "TopN: the column 'a' is a key more than once")
    refused(lambda: _ops.top_n(T, [SortKey("bb")], 3), KeyError, CLOSE_B)
    refused(lambda: _ops.top_n(T, ["a"], 3), TypeError, "top_n keys must hold SortKey values, not str")
    refused(lambda: _ops.top_n(T, [KEY_A], -1), ValueError, "TopN.n must be at least 0")
    refused(lambda: _ops.top_n(T, [KEY_A], False), TypeError, "TopN.n must be an int, not bool")
    refused(lambda: _ops.top_n(None, [KEY_A], 1), TypeError, "top_n plan must be a plan node, not NoneType")


def test_distinct_builds_a_distinct_over_all_columns_or_a_subset():
    assert _ops.distinct(T) == Distinct(T, None)
    assert _ops.distinct(T, None) == Distinct(T)
    assert _ops.distinct(T, ["b", "a"]) == Distinct(T, ("b", "a"))
    assert _ops.distinct(T, ("a",)) == Distinct(T, ("a",))
    assert _ops.distinct(T, ["a"]).columns == ("a", "b", "c")
    assert _ops.distinct(T) != _ops.distinct(T, ["a", "b", "c"])


def test_distinct_refuses_an_empty_repeated_unknown_or_mistyped_subset():
    refused(lambda: _ops.distinct(T, []), ValueError, "Distinct.subset must not be empty")
    refused(lambda: _ops.distinct(T, ["a", "a"]), ValueError, "Distinct: the output name 'a' appears more than once")
    refused(lambda: _ops.distinct(T, ["z"]), KeyError, NO_B)
    refused(lambda: _ops.distinct(T, "a"), TypeError, "distinct subset must be a list or tuple, not str")
    refused(lambda: _ops.distinct(T, [2]), TypeError, "distinct subset must hold str values, not int")
    refused(lambda: _ops.distinct(3), TypeError, "distinct plan must be a plan node, not int")


def test_aggregate_builds_keys_then_named_aggregates():
    total = Agg("sum", (ColRef("a"),))
    rows = Agg("count")
    assert _ops.aggregate(T, ["b"], [("total", total), ("n", rows)]) == Aggregate(
        T, ("b",), (("total", total), ("n", rows))
    )
    assert _ops.aggregate(T, ["b"], [("total", total), ("n", rows)]).columns == ("b", "total", "n")
    assert _ops.aggregate(T, (), (("n", rows),)) == Aggregate(T, (), (("n", rows),))
    assert _ops.aggregate(T, ["a", "b"], []) == Aggregate(T, ("a", "b"), ())
    assert _ops.aggregate(T, ["a", "b"], []).columns == ("a", "b")
    top = Agg("largest_k", (ColRef("a"),), 3)
    assert _ops.aggregate(T, [], [("top", top)]) == Aggregate(T, (), (("top", top),))


def test_aggregate_refuses_bad_keys_names_and_aggregates():
    total = Agg("sum", (ColRef("a"),))
    refused(lambda: _ops.aggregate(T, [], []), ValueError, "Aggregate needs at least one key or one aggregate")
    refused(lambda: _ops.aggregate(T, ["z"], [("n", total)]), KeyError, NO_B)
    refused(lambda: _ops.aggregate(T, ["a", "a"], []), ValueError, "Aggregate: the output name 'a' appears more than once")
    refused(lambda: _ops.aggregate(T, ["a"], [("a", total)]), ValueError, "Aggregate: the output name 'a' appears more than once")
    refused(
        lambda: _ops.aggregate(T, [], [("n", total), ("n", total)]),
        ValueError,
        "Aggregate: the output name 'n' appears more than once",
    )
    refused(lambda: _ops.aggregate(T, [], [("n", Agg("sum", (ColRef("z"),)))]), KeyError, NO_B)
    refused(lambda: _ops.aggregate(T, [], [("n", "sum")]), TypeError, "Aggregate.aggs must hold Agg values, not str")
    refused(lambda: _ops.aggregate(T, [], [("", total)]), ValueError, "Aggregate.agg name must not be empty")
    refused(lambda: _ops.aggregate(T, [], [total]), TypeError, "aggregate aggs must hold (name, value) pairs")
    refused(lambda: _ops.aggregate(T, [], [(1, total)]), TypeError, "aggregate aggs names must be str, not int")
    refused(lambda: _ops.aggregate(T, "a", []), TypeError, "aggregate keys must be a list or tuple, not str")
    refused(lambda: _ops.aggregate(T, [1], []), TypeError, "aggregate keys must hold str values, not int")
    refused(lambda: _ops.aggregate(3, [], [("n", total)]), TypeError, "aggregate plan must be a plan node, not int")


def test_join_builds_a_join_on_keys():
    assert _ops.join(T, U, "inner", ["a"], ["a"]) == Join(T, U, "inner", ("a",), ("a",))
    assert _ops.join(T, U, "left", ("a",), ("a",)) == Join(T, U, "left", ("a",), ("a",), None)
    assert _ops.join(T, U, "inner", ["a"], ["a"]).columns == ("a", "b", "c", "a_right", "d")
    assert _ops.join(T, U, "full", ["b"], ["d"]).columns == ("a", "b", "c", "a_right", "d")


def test_join_semi_and_anti_keep_the_left_columns():
    assert _ops.join(T, U, "semi", ["a"], ["a"]) == Join(T, U, "semi", ("a",), ("a",))
    assert _ops.join(T, U, "semi", ["a"], ["a"]).columns == ("a", "b", "c")
    assert _ops.join(T, U, "anti", ["a"], ["a"]).columns == ("a", "b", "c")


def test_join_cross_takes_no_keys():
    assert _ops.join(T, U, "cross") == Join(T, U, "cross")
    assert _ops.join(T, U, "cross", [], []) == Join(T, U, "cross", (), ())


def test_join_builds_a_join_on_a_residual():
    residual = Compare("gt", ColRef("a", "left"), ColRef("a", "right"))
    assert _ops.join(T, U, "inner", residual=residual) == Join(T, U, "inner", (), (), residual)
    assert _ops.join(T, U, "inner", ["b"], ["d"], residual) == Join(T, U, "inner", ("b",), ("d",), residual)


def test_join_refuses_bad_hows_keys_residuals_and_collisions():
    refused(
        lambda: _ops.join(T, U, "outer", ["a"], ["a"]),
        ValueError,
        "Join op 'outer' is not one of: anti, cross, full, inner, left, right, semi",
    )
    refused(lambda: _ops.join(T, U, "inner"), ValueError, "Join inner needs keys or a residual")
    refused(lambda: _ops.join(T, U, "inner", ["a", "b"], ["a"]), ValueError, "Join: left_on has 2 column(s) and right_on 1")
    refused(lambda: _ops.join(T, U, "cross", ["a"], ["a"]), ValueError, "Join cross takes no keys and no residual")
    refused(
        lambda: _ops.join(T, U, "cross", residual=Compare("gt", ColRef("a", "left"), Lit(1))),
        ValueError,
        "Join cross takes no keys and no residual",
    )
    refused(lambda: _ops.join(T, U, "inner", ["z"], ["a"]), KeyError, NO_B)
    refused(
        lambda: _ops.join(T, U, "inner", ["a"], ["c"]),
        KeyError,
        "no column named 'c' in this frame; the frame's columns are: a, d",
    )
    refused(
        lambda: _ops.join(T, U, "inner", residual=Compare("gt", ColRef("a"), Lit(1))),
        ValueError,
        "Join residual column 'a' has no side; give it side='left' or side='right'",
    )
    refused(
        lambda: _ops.join(T, U, "inner", residual=Compare("gt", ColRef("d", "left"), Lit(1))),
        KeyError,
        "no column named 'd' in this frame; the frame's columns are: a, b, c",
    )
    refused(lambda: _ops.join(T, U, "inner", residual=ColRef("a", "left")), TypeError, "Join residual must be a predicate, not a ColRef")
    refused(lambda: _ops.join(T, U, "inner", ["a"], "a"), TypeError, "join right_on must be a list or tuple, not str")
    refused(lambda: _ops.join(3, U, "inner", ["a"], ["a"]), TypeError, "join left must be a plan node, not int")
    refused(lambda: _ops.join(T, 3, "inner", ["a"], ["a"]), TypeError, "join right must be a plan node, not int")
    clash = Scan("l.parquet", "parquet", (Field("a", "int64"), Field("a_right", "int64")))
    refused(
        lambda: _ops.join(clash, U, "inner", ["a"], ["a"]),
        ValueError,
        "Join: the right column 'a' would be renamed 'a_right', which the frame already has; rename one first",
    )


def test_concat_builds_a_union_of_the_plans_in_order():
    other = Scan("t2.parquet", "parquet", FIELDS)
    third = Filter(T, GT)
    assert _ops.concat([T, other]) == Union((T, other))
    assert _ops.concat((T, other, third)) == Union((T, other, third))
    assert _ops.concat([other, T]) != _ops.concat([T, other])
    assert _ops.concat([T, other]).columns == ("a", "b", "c")


def test_concat_of_one_plan_adds_no_node():
    assert _ops.concat([T]) is T
    assert _ops.concat((U,)) is U


def test_concat_refuses_none_mismatched_columns_and_non_plans():
    refused(lambda: _ops.concat([]), ValueError, "concat needs at least one frame")
    refused(lambda: _ops.concat([T, U]), ValueError, "Union: input 1 has columns (a, d), and the first input has (a, b, c)")
    refused(
        lambda: _ops.concat([T, _ops.select(T, ["b", "a", "c"])]),
        ValueError,
        "Union: input 1 has columns (b, a, c), and the first input has (a, b, c)",
    )
    refused(lambda: _ops.concat([T, 3]), TypeError, "concat plans must be a plan node, not int")
    refused(lambda: _ops.concat(iter([T, T])), TypeError, "concat plans must be a list or tuple, not list_iterator")
    refused(lambda: _ops.concat(T), TypeError, "concat plans must be a list or tuple, not Scan")


def test_write_builds_a_write_root_over_the_plan():
    assert _ops.write(T, "out.parquet", "parquet") == Write(T, WriteTarget("out.parquet", "parquet"))
    assert _ops.write(T, "out.csv", "csv") == Write(T, WriteTarget("out.csv", "csv"))
    assert _ops.write(Filter(T, GT), "o.jsonl", "jsonl").columns == ("a", "b", "c")
    assert _ops.write(T, "a", "csv") != _ops.write(T, "b", "csv")


def test_write_refuses_bad_formats_paths_and_a_write_below_another_node():
    refused(
        lambda: _ops.write(T, "out.orc", "orc"),
        ValueError,
        "WriteTarget format op 'orc' is not one of: csv, jsonl, parquet",
    )
    refused(
        lambda: _ops.write(T, "out.ndjson", "ndjson"),
        ValueError,
        "WriteTarget format op 'ndjson' is not one of: csv, jsonl, parquet",
    )
    refused(lambda: _ops.write(T, "", "csv"), ValueError, "WriteTarget.path must not be empty")
    refused(lambda: _ops.write(T, 3, "csv"), TypeError, "WriteTarget.path must be a str, not int")
    refused(lambda: _ops.write(3, "o.csv", "csv"), TypeError, "write plan must be a plan node, not int")
    written = _ops.write(T, "o.csv", "csv")
    refused(lambda: _ops.write(written, "p.csv", "csv"), TypeError, "a Write can only be the root of a plan")
    refused(lambda: _ops.filter_(written, GT), TypeError, "a Write can only be the root of a plan")
    refused(lambda: _ops.limit(written, 1), TypeError, "a Write can only be the root of a plan")
    refused(lambda: _ops.select(written, ["a", "b"]), TypeError, "a Write can only be the root of a plan")
    refused(lambda: _ops.concat([written, written]), TypeError, "a Write can only be the root of a plan")


def test_verbs_chain_into_one_tree():
    plan = _ops.write(
        _ops.limit(
            _ops.sort(
                _ops.filter_(_ops.rename(_ops.select(T, ["b", "a"]), {"a": "x"}), Compare("gt", ColRef("x"), Lit(0))),
                [SortKey("x", True)],
            ),
            10,
        ),
        "out.csv",
        "csv",
    )
    selected = Project(T, (("b", ColRef("b")), ("a", ColRef("a"))))
    renamed = Project(selected, (("b", ColRef("b")), ("x", ColRef("a"))))
    expected = Write(
        Limit(
            Sort(Filter(renamed, Compare("gt", ColRef("x"), Lit(0))), (SortKey("x", True),)),
            10,
        ),
        WriteTarget("out.csv", "csv"),
    )
    assert plan == expected
    assert hash(plan) == hash(expected)
    assert plan.columns == ("b", "x")


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("ops_verbs: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
