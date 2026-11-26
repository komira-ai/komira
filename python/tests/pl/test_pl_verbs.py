"""komira.pl's verbs and expressions as plans, with no library.

Frames are scans of a stand-in session, a `Session` whose file schemas are
written here as the engine's `WireSchema` bytes and whose terminals record the
plan bytes they are given. For each verb and expression:

- the frame's plan equals a hand-written tree of komira._ops nodes, its
  columns and its order (rules section 7: the sort stays the root, a filter or
  projection goes below it, a limit above it, and over a limit the sort is
  written again);
- the types it lowers by (floor division over integers and over floats, a
  boolean column as a predicate, the types polars gives a sum, a mean and a
  count) and the output names polars gives;
- each refusal raises its class with its full message: an unknown column, an
  aggregate beside a row-wise value, an order-dependent verb on an unordered
  frame, a stable sort, a regular expression, a negative count, frames of
  two sessions or of different columns;
- `collect()` hands the session the bytes of a `WirePlanEnvelope` that holds
  no SQL text, and `schema` gives pyarrow types.

The test loads no library and is of the `pl/` family (python/tests/BUCK): it
runs on each supported minor, with the generated plan modules, protobuf 7.36.2
and pyarrow.

    test_pl_verbs.py
"""

import os
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._ops import (
    Agg,
    Aggregate,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Field,
    Filter,
    Limit,
    Lit,
    MathFn,
    Project,
    Scan,
    Sort,
    SortKey,
    StringFn,
    StringOp,
    TopN,
    Unary,
    Union,
    When,
)
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "t.parquet")
TYPES = [
    ("id", "int64"),
    ("x", "int64"),
    ("y", "float64"),
    ("g", "string"),
    ("flag", "bool"),
    ("i32", "int32"),
    ("f32", "float32"),
    ("u16", "uint16"),
]
T = Scan(PATH, "parquet", tuple(Field(n, t) for n, t in TYPES))


class StandIn(Session):
    """A session with no library: schemas from `schemas`, plans recorded."""

    def __init__(self, schemas):
        self.schemas = schemas
        self.ran = []
        self.rendered = []

    def _parquet_schema(self, path):
        fields = [field(n, arrow_id(t), True) for n, t in self.schemas[path]]
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def _plan_render(self, plan):
        self.rendered.append(plan)
        return "rendered"

    def close(self):
        pass


SESSION = StandIn({PATH: TYPES})


def frame():
    return kpl.scan_parquet(PATH, session=SESSION)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    text = e.args[0] if isinstance(e, KeyError) else str(e)
    assert text == message, text


def c(name):
    return ColRef(name)


# ---- readers -----------------------------------------------------------------


def test_scan_parquet_is_a_scan_of_the_file_with_its_columns():
    lf = frame()
    assert lf._plan == T
    assert lf.columns == [n for n, _ in TYPES]
    assert lf.width == len(TYPES)
    assert lf._order is None
    assert lf._session is SESSION


def test_scan_refuses_a_list_of_files_and_a_non_session():
    refused(
        lambda: kpl.scan_parquet([PATH], session=SESSION),
        UnsupportedOperation,
        "scan_parquet: a list of files is not supported yet; read one file",
    )
    refused(lambda: kpl.scan_parquet(PATH, session=1), TypeError, "session must be a komira.Session, not int")


# ---- select and with_columns ---------------------------------------------------


def test_select_of_names_is_a_projection_of_references():
    lf = frame().select("x", kpl.col("id"))
    assert lf._plan == Project(T, (("x", c("x")), ("id", c("id"))))


def test_select_of_every_column_in_order_adds_no_node():
    assert frame().select([n for n, _ in TYPES])._plan == T


def test_select_names_outputs_by_the_leftmost_column_or_literal():
    lf = frame().select(kpl.col("x") + 1, 10 - kpl.col("y"), (kpl.col("id") * 2).alias("d"))
    assert lf.columns == ["x", "literal", "d"]
    assert lf._plan == Project(
        T,
        (
            ("x", Arith("add", c("x"), Lit(1))),
            ("literal", Arith("sub", Lit(10), c("y"))),
            ("d", Arith("mul", c("id"), Lit(2))),
        ),
    )


def test_select_refuses_two_outputs_of_one_name_and_an_unknown_column():
    refused(
        lambda: frame().select(kpl.col("x"), kpl.col("x") + 1),
        ValueError,
        "select: the output name 'x' is produced by more than one expression; "
        "give each a name of its own with .alias(...)",
    )
    refused(
        lambda: frame().select(kpl.col("xx")),
        KeyError,
        "no column named 'xx' in this frame; the closest is 'x'; the frame's columns are: "
        "id, x, y, g, flag, i32, f32, u16",
    )
    refused(lambda: frame().select(), ValueError, "select needs at least one column or expression")
    refused(lambda: frame().select(3), TypeError, "select takes column names and komira.pl expressions, not int")


def test_select_of_literals_only_is_refused():
    refused(
        lambda: frame().select(kpl.lit(1)),
        UnsupportedOperation,
        "select: an expression of literals only has no rows of the frame to give it; "
        "add it to the frame with with_columns(...)",
    )


def test_with_columns_replaces_in_place_and_appends():
    lf = frame().with_columns(kpl.col("x") * 2, (kpl.col("y") + 1).alias("y1"), z=5)
    items = [(n, c(n)) for n, _ in TYPES]
    items[1] = ("x", Arith("mul", c("x"), Lit(2)))
    items += [("y1", Arith("add", c("y"), Lit(1))), ("z", Cast(Lit(5), "int32"))]
    assert lf._plan == Project(T, tuple(items))
    assert frame().with_columns()._plan == T


def test_with_columns_refuses_an_aggregate():
    refused(
        lambda: frame().with_columns(kpl.col("x").sum().alias("t")),
        UnsupportedOperation,
        "with_columns: 't' is an aggregate, which would be broadcast over the rows (a window); "
        "that is not supported yet",
    )


# ---- expressions ---------------------------------------------------------------


def lowered(expr):
    return frame().select(expr.alias("o"))._plan.items[0][1]


def test_true_division_is_float64_and_float32_quotients_are_cast_back():
    assert lowered(kpl.col("x") / 2) == Arith("div", Cast(c("x"), "float64"), Lit(2.0))
    assert lowered(kpl.col("i32") / kpl.col("y")) == Arith("div", Cast(c("i32"), "float64"), c("y"))
    f64 = Cast(c("f32"), "float64")
    assert lowered(kpl.col("f32") / kpl.col("f32")) == Cast(Arith("div", f64, f64), "float32")
    assert lowered(kpl.col("f32") / 2) == Cast(Arith("div", f64, Lit(2.0)), "float32")
    refused(
        lambda: frame().select(kpl.col("g") / 2),
        UnsupportedOperation,
        "/ needs numbers (int32, int64, float32, float64), and an operand is of type string",
    )


def test_floor_division_and_modulo_by_a_literal_read_its_sign():
    r = Arith("mod", c("x"), Lit(3))
    assert lowered(kpl.col("x") // 3) == Arith(
        "sub", Arith("div", c("x"), Lit(3)), When(((Compare("lt", r, Lit(0)), Lit(1)),), Lit(0))
    )
    assert lowered(kpl.col("x") % 3) == Arith("add", r, When(((Compare("lt", r, Lit(0)), Lit(3)),), Lit(0)))
    rn = Arith("mod", c("x"), Lit(-3))
    assert lowered(kpl.col("x") % -3) == Arith(
        "add", rn, When(((Compare("gt", rn, Lit(0)), Lit(-3)),), Lit(0))
    )
    assert lowered(kpl.col("x") // 0) == Arith("div", c("x"), Lit(0))
    assert lowered(kpl.col("x") % 0) == Arith("mod", c("x"), Lit(0))


def test_floor_division_and_modulo_by_a_column_compare_no_predicates():
    b = Cast(c("i32"), "int64")
    r = Arith("mod", c("x"), b)
    differs = BoolOp(
        "or",
        BoolOp("and", Compare("lt", r, Lit(0)), Compare("gt", b, Lit(0))),
        BoolOp("and", Compare("gt", r, Lit(0)), Compare("lt", b, Lit(0))),
    )
    assert lowered(kpl.col("x") % kpl.col("i32")) == Arith("add", r, When(((differs, b),), Lit(0)))


def test_floor_division_of_int32_is_computed_as_int64_and_cast_back():
    a = Cast(c("i32"), "int64")
    r = Arith("mod", Lit(-7), a)
    differs = BoolOp(
        "or",
        BoolOp("and", Compare("lt", r, Lit(0)), Compare("gt", a, Lit(0))),
        BoolOp("and", Compare("gt", r, Lit(0)), Compare("lt", a, Lit(0))),
    )
    assert lowered(-7 // kpl.col("i32")) == Cast(
        Arith("sub", Arith("div", Lit(-7), a), When(((differs, Lit(1)),), Lit(0))), "int32"
    )


def test_floats_floor_and_take_the_sign_of_the_divisor():
    assert lowered(kpl.col("y") // 2) == MathFn("floor", Arith("div", c("y"), Lit(2.0)))
    r = Arith("mod", c("y"), Lit(-2.0))
    assert lowered(kpl.col("y") % -2.0) == Arith(
        "add", r, When(((Compare("gt", r, Lit(0)), Lit(-2.0)),), Lit(0.0))
    )
    r32 = Arith("mod", Cast(c("f32"), "float64"), Lit(2.0))
    assert lowered(kpl.col("f32") % 2) == Cast(
        Arith("add", r32, When(((Compare("lt", r32, Lit(0)), Lit(2.0)),), Lit(0.0))), "float32"
    )


def test_int32_and_float32_arithmetic_is_computed_wide_and_cast_back():
    i64 = Cast(c("i32"), "int64")
    assert lowered(1 + kpl.col("i32")) == Cast(Arith("add", Lit(1), i64), "int32")
    assert lowered(kpl.col("i32") * kpl.col("i32")) == Cast(Arith("mul", i64, i64), "int32")
    assert lowered(kpl.col("f32") * 2.5) == Cast(Arith("mul", Cast(c("f32"), "float64"), Lit(2.5)), "float32")
    assert lowered(kpl.col("x") - 1) == Arith("sub", c("x"), Lit(1))
    assert lowered(kpl.col("i32") + 2**40) == Arith("add", i64, Lit(2**40))
    assert lowered(kpl.col("i32") + kpl.col("x")) == Arith("add", i64, c("x"))
    assert lowered(kpl.col("i32") > 3) == Compare("gt", i64, Lit(3))
    assert lowered(kpl.col("f32") <= kpl.col("y")) == Compare("le", Cast(c("f32"), "float64"), c("y"))
    assert lowered(kpl.col("i32").is_in([1])) == Compare("eq", i64, Lit(1))
    assert lowered(kpl.col("i32").is_between(1, 2)) == BoolOp(
        "and", Compare("ge", i64, Lit(1)), Compare("le", i64, Lit(2))
    )
    assert frame().with_columns(big=2**40, small=7)._plan.items[-2:] == (
        ("big", Lit(2**40)),
        ("small", Cast(Lit(7), "int32")),
    )


def test_operators_and_reflected_operators():
    assert lowered(2 * kpl.col("x")) == Arith("mul", Lit(2), c("x"))
    assert lowered(-kpl.col("x")) == Unary("negate", c("x"))
    assert lowered(+kpl.col("x")) == c("x")
    assert lowered(kpl.col("x").abs()) == Unary("abs", c("x"))
    assert lowered((kpl.col("x") > 1) & (kpl.col("y") <= 2)) == BoolOp(
        "and", Compare("gt", c("x"), Lit(1)), Compare("le", c("y"), Lit(2))
    )
    assert lowered((kpl.col("x") == 1) | (kpl.col("x") != 2)) == BoolOp(
        "or", Compare("eq", c("x"), Lit(1)), Compare("ne", c("x"), Lit(2))
    )
    assert lowered(~(kpl.col("x") >= 1)) == Unary("not", Compare("ge", c("x"), Lit(1)))
    assert lowered((kpl.col("x") < 1).not_()) == Unary("not", Compare("lt", c("x"), Lit(1)))


def test_a_boolean_column_is_compared_with_true_where_a_predicate_is_needed():
    flag = Compare("eq", c("flag"), Lit(True))
    assert lowered(kpl.col("flag") & (kpl.col("x") > 0)) == BoolOp("and", flag, Compare("gt", c("x"), Lit(0)))
    assert lowered(~kpl.col("flag")) == Unary("not", flag)
    assert frame().filter(kpl.col("flag"))._plan == Filter(T, flag)
    refused(
        lambda: frame().filter(kpl.col("x")),
        TypeError,
        "filter needs a boolean expression, and this one is of type int64",
    )


def test_missing_values_membership_and_cast():
    assert lowered(kpl.col("x").is_null()) == Unary("is_null", c("x"))
    assert lowered(kpl.col("x").is_not_null()) == Unary("is_not_null", c("x"))
    assert lowered(kpl.col("x").fill_null(0)) == When(((Unary("is_null", c("x")), Lit(0)),), c("x"))
    assert lowered(kpl.col("x").is_in([1, 2])) == BoolOp(
        "or", Compare("eq", c("x"), Lit(1)), Compare("eq", c("x"), Lit(2))
    )
    assert lowered(kpl.col("x").is_between(1, 2, closed="left")) == BoolOp(
        "and", Compare("ge", c("x"), Lit(1)), Compare("lt", c("x"), Lit(2))
    )
    assert lowered(kpl.col("x").cast("float32")) == Cast(c("x"), "float32")
    assert lowered(kpl.col("x").cast(pa.string(), strict=False)) == Cast(c("x"), None, True, arrow="string")
    assert lowered(kpl.col("y").cast(pa.float64())) == c("y")
    assert lowered(kpl.col("y").cast("int64")) == Cast(Unary("trunc", c("y")), "int64")
    assert lowered(kpl.col("u16").cast("int32")) == Cast(c("u16"), "int32")
    assert lowered(kpl.col("g").cast("float64")) == Cast(c("g"), "float64")
    i32 = Cast(When(((Unary("is_null", c("i32")), Lit(0)),), Cast(c("i32"), "int64")), "int32")
    assert lowered(kpl.col("i32").fill_null(0)) == i32
    assert lowered(kpl.col("x").fill_null(0.5)) == When(
        ((Unary("is_null", c("x")), Lit(0.5)),), Cast(c("x"), "float64")
    )


def test_expression_refusals():
    refused(
        lambda: kpl.col("x").fill_null(strategy="forward"),
        UnsupportedOperation,
        "fill_null: strategy= and limit= fill from neighbouring rows, which a plan does not order; "
        "fill with a value: fill_null(value)",
    )
    refused(lambda: kpl.col("x").fill_null(), TypeError, "fill_null needs a value")
    refused(
        lambda: kpl.col("x").is_in(kpl.col("y")),
        UnsupportedOperation,
        "is_in takes a list or tuple of values, not Expr",
    )
    refused(
        lambda: kpl.col("x").is_between(1, 2, closed="up"),
        ValueError,
        "is_between: closed 'up' is not one of: both, left, right, none",
    )
    refused(
        lambda: kpl.col("x").cast("object"),
        UnsupportedOperation,
        "cast: the dtype 'object' is not supported; use one of: bool, float32, float64, int16, "
        "int32, int64, int8, string, uint16, uint32, uint64, uint8",
    )
    refused(lambda: kpl.col("x").cast(int), TypeError, "cast: a dtype is a pyarrow.DataType or a dtype name, not type")
    refused(
        lambda: frame().select(kpl.col("x").cast("bool")),
        UnsupportedOperation,
        "cast: a cast from int64 to bool is not supported yet",
    )
    refused(
        lambda: frame().select(kpl.col("flag").fill_null(False)),
        UnsupportedOperation,
        "fill_null: a branch of type bool is not supported yet; the branches must be numbers "
        "(int32, int64, float32, float64) or strings",
    )
    refused(
        lambda: frame().select(kpl.when(kpl.col("x") > 0).then(kpl.col("g")).otherwise(kpl.col("x"))),
        UnsupportedOperation,
        "when: the branches mix strings and numbers; cast them to one type first",
    )
    refused(
        lambda: frame().select(kpl.col("g").sum()),
        UnsupportedOperation,
        "sum of a column of type string is not supported yet",
    )
    refused(
        lambda: kpl.col("s").str.contains("a.c"),
        UnsupportedOperation,
        "str.contains: a regular expression pattern is not supported yet; match the text itself "
        "with str.contains(pattern, literal=True)",
    )
    refused(
        lambda: kpl.col(["a", "b"]),
        UnsupportedOperation,
        "col() takes one column name, a str, not list; name each column with its own col()",
    )
    refused(
        lambda: kpl.col("*"),
        UnsupportedOperation,
        "col('*') selects columns by pattern, which is not supported yet; name each column with its own col()",
    )
    refused(lambda: kpl.lit(object()), TypeError, "a literal must be None, bool, int, float, str, bytes, a Decimal or a date, time or timedelta, not object")
    refused(lambda: kpl.col("x").alias(1), TypeError, "alias: the name must be a str, not int")
    refused(lambda: kpl.col("x").std(ddof=0), UnsupportedOperation, "std: ddof=0 is not supported; only ddof=1 is")
    refused(
        lambda: kpl.col("x").sum().sum(),
        UnsupportedOperation,
        "sum: 'x' is already an aggregate; an aggregate of an aggregate is not supported",
    )
    refused(
        lambda: bool(kpl.col("x") > 1),
        TypeError,
        "the truth value of an Expr is ambiguous: combine predicates with & and | and negate one with ~, "
        "not with and, or and not",
    )


def test_strings():
    assert lowered(kpl.col("g").str.to_lowercase()) == StringFn("lower", c("g"))
    assert lowered(kpl.col("g").str.to_uppercase()) == StringFn("upper", c("g"))
    assert lowered(kpl.col("g").str.len_chars()) == StringFn("length", c("g"))
    assert lowered(kpl.col("g").str.starts_with("a")) == StringOp("starts_with", c("g"), "a")
    assert lowered(kpl.col("g").str.ends_with("a")) == StringOp("ends_with", c("g"), "a")
    assert lowered(kpl.col("g").str.contains("a", literal=True)) == StringOp("contains", c("g"), "a")


def test_when_then_otherwise_is_named_after_the_first_then():
    e = kpl.when(kpl.col("x") > 0).then(kpl.col("y")).when(kpl.col("flag")).then(1.0).otherwise(0.0)
    lf = frame().select(e)
    assert lf.columns == ["y"]
    assert lf._plan.items[0][1] == When(
        (
            (Compare("gt", c("x"), Lit(0)), c("y")),
            (Compare("eq", c("flag"), Lit(True)), Lit(1.0)),
        ),
        Lit(0.0),
    )
    refused(
        lambda: kpl.when(kpl.col("flag")).then(1).alias("a"),
        AttributeError,
        "when(...).then(...) needs .otherwise(value) before .alias(): say what the rows no condition holds for are",
    )


# ---- aggregates ----------------------------------------------------------------


def test_a_select_of_bare_aggregates_is_one_aggregate_named_by_polars():
    lf = frame().select(kpl.col("x").min(), kpl.col("y").max().alias("top"))
    assert lf._plan == Aggregate(T, (), (("x", Agg("min", (c("x"),))), ("top", Agg("max", (c("y"),)))))
    assert lf._order is None


def test_sum_count_len_and_statistics_carry_polars_types():
    lf = frame().select(
        kpl.col("x").sum(),
        kpl.col("i32").sum(),
        kpl.col("x").count().alias("n"),
        kpl.len(),
        kpl.col("f32").mean(),
        kpl.col("y").std(),
    )
    slots = [f"__komira_agg_{i}" for i in range(6)]

    def zero(ref):
        return When(((Unary("is_null", ref), Lit(0)),), ref)

    assert lf._plan == Project(
        Aggregate(
            T,
            (),
            (
                (slots[0], Agg("sum", (c("x"),))),
                (slots[1], Agg("sum", (Cast(c("i32"), "int64"),))),
                (slots[2], Agg("count", (c("x"),))),
                (slots[3], Agg("count")),
                (slots[4], Agg("mean", (Cast(c("f32"), "float64"),))),
                (slots[5], Agg("stddev_samp", (c("y"),))),
            ),
        ),
        (
            ("x", zero(c(slots[0]))),
            ("i32", Cast(zero(c(slots[1])), "int32")),
            ("n", c(slots[2])),
            ("len", c(slots[3])),
            ("f32", Cast(c(slots[4]), "float32")),
            ("y", c(slots[5])),
        ),
    )


def test_the_sum_of_a_boolean_counts_its_trues():
    lf = frame().select(kpl.col("flag").sum(), (kpl.col("x") > 0).sum().alias("positive"))
    ones = When(((Compare("eq", c("flag"), Lit(True)), Lit(1)),), Lit(0))
    positive = When(((Compare("gt", c("x"), Lit(0)), Lit(1)),), Lit(0))

    def zero(ref):
        return When(((Unary("is_null", ref), Lit(0)),), ref)

    assert lf._plan == Project(
        Aggregate(T, (), (("__komira_agg_0", Agg("sum", (ones,))), ("__komira_agg_1", Agg("sum", (positive,))))),
        (("flag", zero(c("__komira_agg_0"))), ("positive", zero(c("__komira_agg_1")))),
    )


def test_n_unique_counts_null_as_one_value():
    lf = frame().select(kpl.col("g").n_unique())
    distinct, rows, values = c("__komira_agg_0"), c("__komira_agg_1"), c("__komira_agg_2")
    assert lf._plan == Project(
        Aggregate(
            T,
            (),
            (
                ("__komira_agg_0", Agg("count_distinct", (c("g"),))),
                ("__komira_agg_1", Agg("count")),
                ("__komira_agg_2", Agg("count", (c("g"),))),
            ),
        ),
        (("g", Arith("add", distinct, When(((Compare("gt", rows, values), Lit(1)),), Lit(0)))),),
    )


def test_an_aggregate_name_never_takes_a_column_or_output_name():
    lf = frame().select(kpl.col("x").sum().alias("__komira_agg_0"))
    assert lf._plan.child.aggs[0][0] == "___komira_agg_0"


def test_min_and_max_of_int32_and_float32_are_picked_wide_and_cast_back():
    lf = frame().select(kpl.col("i32").min(), kpl.col("f32").max(), kpl.col("u16").max())
    assert lf._plan == Project(
        Aggregate(
            T,
            (),
            (
                ("__komira_agg_0", Agg("min", (Cast(c("i32"), "int64"),))),
                ("__komira_agg_1", Agg("max", (Cast(c("f32"), "float64"),))),
                ("__komira_agg_2", Agg("max", (c("u16"),))),
            ),
        ),
        (
            ("i32", Cast(c("__komira_agg_0"), "int32")),
            ("f32", Cast(c("__komira_agg_1"), "float32")),
            ("u16", c("__komira_agg_2")),
        ),
    )


def test_aggregate_below_a_sort_drops_the_sort():
    lf = frame().sort("id").select(kpl.col("x").max())
    assert lf._plan == Aggregate(T, (), (("x", Agg("max", (c("x"),))),))


def test_an_aggregate_beside_a_row_wise_value_is_refused():
    refused(
        lambda: frame().select(kpl.col("x").sum(), kpl.col("y")),
        UnsupportedOperation,
        "select: the column 'y' is used beside an aggregate; an aggregate broadcast over rows "
        "(a window) is not supported yet, so aggregate every column of this select()",
    )
    refused(
        lambda: frame().filter(kpl.col("x").sum() > 1),
        UnsupportedOperation,
        "filter: a predicate over an aggregate needs a window, which is not supported yet",
    )


# ---- order -------------------------------------------------------------------


def test_sort_writes_each_key_with_polars_null_placement():
    lf = frame().sort("x", kpl.col("y"), descending=[True, False], nulls_last=[False, True])
    keys = (SortKey("x", True, True), SortKey("y", False, False))
    assert lf._plan == Sort(T, keys)
    assert lf._order == keys
    assert frame().sort("x").sort("y")._plan == Sort(T, (SortKey("y", False, True),))


def test_sort_refusals():
    refused(
        lambda: frame().sort("x", maintain_order=True),
        UnsupportedOperation,
        "sort: maintain_order=True keeps tied rows in input order, and no sort in the plan is stable; "
        "sort by more columns to break the ties",
    )
    refused(
        lambda: frame().sort(kpl.col("x") + 1),
        UnsupportedOperation,
        "sort: sorting by the expression 'x' is not supported; add it with with_columns(...) and sort by its name",
    )
    refused(lambda: frame().sort("x", "y", descending=[True]), ValueError, "sort: descending has 1 values for 2 sort columns")
    refused(lambda: frame().sort("x", nulls_last="yes"), TypeError, "sort: nulls_last must be a bool or a list of bools")


def test_filter_and_projection_go_below_the_sort():
    keys = (SortKey("id", False, True),)
    lf = frame().sort("id").filter(kpl.col("x") > 0).select("id", "x")
    assert lf._plan == Sort(Project(Filter(T, Compare("gt", c("x"), Lit(0))), (("id", c("id")), ("x", c("x")))), keys)
    assert lf._order == keys


def test_a_projection_that_drops_a_sort_key_makes_the_frame_unordered():
    lf = frame().sort("id").select("x")
    assert lf._plan == Project(Sort(T, (SortKey("id", False, True),)), (("x", c("x")),))
    assert lf._order is None


def test_over_a_limit_the_sort_is_written_again():
    keys = (SortKey("id", False, True),)
    lf = frame().sort("id").head(3).filter(kpl.col("x") > 0)
    assert lf._plan == Sort(Filter(Limit(Sort(T, keys), 3), Compare("gt", c("x"), Lit(0))), keys)
    renamed = frame().sort("id").head(3).rename({"id": "key"})
    assert renamed._order == (SortKey("key", False, True),)
    assert isinstance(renamed._plan, Sort) and isinstance(renamed._plan.child, Project)


def test_head_slice_and_tail():
    keys = (SortKey("id", False, True),)
    assert frame().head()._plan == Limit(T, 5)
    assert frame().limit(2)._plan == Limit(T, 2)
    assert frame().sort("id").slice(2, 3)._plan == Limit(Sort(T, keys), 3, 2)
    assert frame().slice(0, 3)._plan == Limit(T, 3)
    flipped = (SortKey("id", True, False),)
    tail = frame().sort("id").tail(2)
    assert tail._plan == Sort(TopN(T, flipped, 2), keys)
    assert tail._order == keys


def test_order_dependent_verbs_refuse_an_unordered_frame():
    message = (
        "{} needs an ordered frame, and a plan promises no row order unless it is sorted; "
        "sort(...) the frame first"
    )
    refused(lambda: frame().tail(2), UnsupportedOperation, message.format("tail"))
    refused(lambda: frame().slice(1, 2), UnsupportedOperation, message.format("slice with an offset"))
    refused(
        lambda: frame().head(-1),
        UnsupportedOperation,
        "head: a negative n counts from the end of the frame, which is not supported",
    )
    refused(lambda: frame().head(1.5), TypeError, "head: n must be an int, not float")
    refused(
        lambda: frame().slice(1),
        UnsupportedOperation,
        "slice: give a length; slice(offset) with no length is not supported",
    )


def test_top_k_and_bottom_k_prefer_values_to_nulls_and_are_unordered():
    lf = frame().top_k(3, by="x")
    assert lf._plan == TopN(T, (SortKey("x", True, False),), 3)
    assert lf._order is None
    assert frame().bottom_k(2, by=["y", "x"], reverse=[False, True])._plan == TopN(
        T, (SortKey("y", False, False), SortKey("x", True, False)), 2
    )
    assert frame().top_k(1, by="x", reverse=True)._plan == TopN(T, (SortKey("x", False, False),), 1)


# ---- drop, rename, drop_nulls, concat --------------------------------------------


def test_drop_rename_and_drop_nulls():
    kept = tuple((n, c(n)) for n, _ in TYPES if n not in ("g", "flag"))
    assert frame().drop("g", ["flag"])._plan == Project(T, kept)
    assert frame().drop("nope", strict=False)._plan == T
    refused(lambda: frame().drop("nope"), KeyError, "no column named 'nope' in this frame; the frame's columns are: id, x, y, g, flag, i32, f32, u16")
    renamed = frame().rename({"x": "x2"})
    assert renamed.columns == ["id", "x2", "y", "g", "flag", "i32", "f32", "u16"]
    assert frame().rename(str.upper).columns == [n.upper() for n, _ in TYPES]
    assert frame().rename({"nope": "a"}, strict=False)._plan == T
    assert frame().drop_nulls("x")._plan == Filter(T, Unary("is_not_null", c("x")))
    assert frame().drop_nulls([])._plan == T


def test_concat_is_a_union_of_frames_of_one_session_and_columns():
    a, b = frame(), frame().filter(kpl.col("x") > 0)
    assert kpl.concat([a, b])._plan == Union((T, Filter(T, Compare("gt", c("x"), Lit(0)))))
    assert kpl.concat([a])._plan == T
    other = StandIn({PATH: TYPES})
    refused(
        lambda: kpl.concat([a, kpl.scan_parquet(PATH, session=other)]),
        UnsupportedOperation,
        "concat: frame 1 runs on another session than frame 0; frames of two sessions never meet",
    )
    refused(
        lambda: kpl.concat([a, a.select("x", "id")]),
        UnsupportedOperation,
        "concat: frame 1 has the columns (x, id) and frame 0 has (id, x, y, g, flag, i32, f32, u16); "
        "how='vertical' needs the same names in the same order",
    )
    refused(
        lambda: kpl.concat([a.select("x"), a.select(kpl.col("y").alias("x"))]),
        UnsupportedOperation,
        "concat: the column 'x' is of type double in frame 1 and int64 in frame 0; cast it to one type first",
    )
    refused(lambda: kpl.concat([a], how="diagonal"), UnsupportedOperation, "concat: how='diagonal' is not supported; only how='vertical' is")
    refused(lambda: kpl.concat([]), ValueError, "concat needs at least one frame")


# ---- terminals ----------------------------------------------------------------


def test_collect_hands_the_session_plan_bytes_with_no_sql_text():
    SESSION.ran.clear()
    lf = frame().filter(kpl.col("x") > 0).sort("id").head(2).select("id")
    assert lf.collect() == "result"
    assert lf.explain() == "rendered"
    (plan,) = SESSION.ran
    assert SESSION.rendered[-1] == plan
    envelope = pb.WirePlanEnvelope()
    envelope.ParseFromString(plan)
    for word in (b"SELECT", b"FROM", b"WHERE", b"ORDER BY", b"LIMIT"):
        assert word not in plan, word
    assert [f.name for f in envelope.plan.output_schema.fields] == ["id"]


def test_schema_names_dates_timestamps_and_string_layouts():
    path = os.path.join(tempfile.gettempdir(), "typed.parquet")
    session = StandIn({path: [("d", "date32"), ("ts", "timestamp_us"), ("big", "large_string")]})
    lf = kpl.scan_parquet(path, session=session)
    assert lf.schema == {"d": pa.date32(), "ts": pa.timestamp("us"), "big": pa.large_string()}
    assert lf.select(kpl.col("big").cast("string"))._plan.items[0][1] == c("big")


def test_schema_is_pyarrow_types_derived_without_running():
    SESSION.ran.clear()
    lf = frame().select(
        "g",
        (kpl.col("x") / 2).alias("half"),
        kpl.col("g").str.len_chars().alias("n"),
        (kpl.col("x") > 1).alias("big"),
    )
    assert lf.schema == {"g": pa.string(), "half": pa.float64(), "n": pa.int64(), "big": pa.bool_()}
    assert lf.collect_schema() == lf.schema
    assert frame().select(kpl.len(), kpl.col("i32").sum(), kpl.col("f32").sum()).schema == {
        "len": pa.int64(),
        "i32": pa.int32(),
        "f32": pa.float32(),
    }
    assert SESSION.ran == []
    assert repr(frame().select("g", "x")) == "<komira.pl.LazyFrame [g: string, x: int64]>"


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_verbs: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
