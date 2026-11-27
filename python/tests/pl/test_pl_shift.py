"""komira.pl's `Expr.shift` and `Expr.diff` as plans, with no library.

Frames are scans of a stand-in session whose file schema is written here as
the engine's `WireSchema` bytes and whose terminal records the plan bytes it is
given (as test_pl_frames.py does). Checked:

- the frame's plan equals a hand-written tree of komira._ops nodes: `shift(n)`
  is a LAG window of n rows in the frame's sort order (or `over(order_by=...)`,
  per partition of `over`), `shift(-n)` a LEAD of n rows, `shift(0)` the column;
  `diff(n)` the column less that window; an int8 to int32 or a float32 column
  is read through an int64 or float64 argument column and the answer cast
  back; the sort of an ordered frame is written again on top;
- the types, as `schema` names them without running: shift keeps every type it
  reads (Int64, Int32, Float64, Float32, String), and diff keeps the integer
  type (Int64 stays Int64, Int32 stays Int32), as polars does;
- each refusal raises its class with its full message: an unsorted frame,
  `fill_value`, `null_behavior="drop"` and an unknown null_behavior, an `n`
  that is not an int, a column type the windows do not read (bool, unsigned,
  string for diff), and a shift of an aggregate;
- `collect()` hands the session plan bytes that hold no SQL text.

The test loads no library and is of the `pl/` family (python/tests/BUCK): it
runs on each supported minor, with the generated plan modules, protobuf 7.36.2
and pyarrow.

    test_pl_shift.py
"""

import os
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._ops import Arith, Cast, ColRef, Field, Project, Scan, Sort, SortKey, WindowExpr
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "shift_left.parquet")
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
ALL = tuple((n, ColRef(n)) for n, _ in TYPES)
ID_ORDER = (SortKey("id", False, True),)
NOT_SORTED = (
    "with_columns: {what} reads the rows in order, and a plan promises no row order unless it is "
    "sorted; sort(...) the frame first, or give the order with .over(..., order_by=...)"
)


class StandIn(Session):
    """A session with no library: the schema from TYPES, plans recorded."""

    def __init__(self):
        self.ran = []

    def _parquet_schema(self, path):
        fields = [field(n, arrow_id(t), True) for n, t in TYPES]
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def close(self):
        pass


SESSION = StandIn()


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
    assert str(e) == message, str(e)


def c(name):
    return ColRef(name)


def extend(plan, items):
    """A PROJECT of every column of `plan`, then the `items` (name, node)."""
    return Project(plan, tuple((n, c(n)) for n in plan.columns) + tuple(items))


def win(i):
    return f"__komira_win_{i}"


def arg(i):
    return f"__komira_arg_{i}"


def lag(column, n, order=ID_ORDER, partition=()):
    return WindowExpr("lag", column, n, partition, order)


def lead(column, n, order=ID_ORDER, partition=()):
    return WindowExpr("lead", column, n, partition, order)


def sorted_with(wins, out, pre=()):
    """The frame sorted by id with the column `r` = `out` over the windows
    `wins` (and the argument columns `pre` under them)."""
    base = extend(T, pre) if pre else T
    return Sort(Project(extend(base, wins), ALL + (("r", out),)), ID_ORDER)


# ---- shift -------------------------------------------------------------------------


def test_shift_is_a_lag_window_in_the_frame_order_and_keeps_the_type():
    for column, dtype in (("x", pa.int64()), ("y", pa.float64()), ("g", pa.string())):
        for n in (1, 2):
            lf = frame().sort("id").with_columns(kpl.col(column).shift(n).alias("r"))
            assert lf._plan == sorted_with([(win(0), lag(column, n))], c(win(0))), (column, n)
            assert lf._order == ID_ORDER
            assert lf.schema["r"] == dtype, (column, n)
    lf = frame().sort("id").with_columns(kpl.col("x").shift().alias("r"))
    assert lf._plan == sorted_with([(win(0), lag("x", 1))], c(win(0)))


def test_shift_of_a_negative_n_is_a_lead_of_the_rows_after():
    lf = frame().sort("id").with_columns(kpl.col("x").shift(-3).alias("r"))
    assert lf._plan == sorted_with([(win(0), lead("x", 3))], c(win(0)))
    assert lf.schema["r"] == pa.int64()


def test_shift_of_zero_is_the_column_itself():
    lf = frame().sort("id").with_columns(kpl.col("x").shift(0).alias("r"))
    assert lf._plan == Sort(Project(T, ALL + (("r", c("x")),)), ID_ORDER)


def test_shift_of_a_narrow_column_reads_it_through_the_wide_type_and_casts_back():
    for column, wide, dtype in (("i32", "int64", "int32"), ("f32", "float64", "float32")):
        lf = frame().sort("id").with_columns(kpl.col(column).shift(1).alias("r"))
        pre = [(arg(0), Cast(c(column), wide))]
        assert lf._plan == sorted_with([(win(0), lag(arg(0), 1))], Cast(c(win(0)), dtype), pre), column
        assert lf.schema["r"] == pa.type_for_alias(dtype), column


def test_shift_over_a_partition_and_an_order_reads_each_partition_on_an_unordered_frame():
    lf = frame().with_columns(kpl.col("x").shift(1).over("g", order_by="id").alias("r"))
    assert lf._plan == Project(extend(T, [(win(0), lag("x", 1, partition=("g",)))]), ALL + (("r", c(win(0))),))
    assert lf._order is None


# ---- diff --------------------------------------------------------------------------


def test_diff_subtracts_the_shift_and_keeps_the_int_type_as_polars_does():
    for n, window in ((1, lag("x", 1)), (2, lag("x", 2)), (-1, lead("x", 1))):
        lf = frame().sort("id").with_columns(kpl.col("x").diff(n).alias("r"))
        assert lf._plan == sorted_with([(win(0), window)], Arith("sub", c("x"), c(win(0)))), n
        assert lf.schema["r"] == pa.int64(), n
    lf = frame().sort("id").with_columns(kpl.col("y").diff().alias("r"))
    assert lf._plan == sorted_with([(win(0), lag("y", 1))], Arith("sub", c("y"), c(win(0))))
    assert lf.schema["r"] == pa.float64()


def test_diff_of_an_int32_column_is_an_int32():
    lf = frame().sort("id").with_columns(kpl.col("i32").diff().alias("r"))
    wide = Cast(c("i32"), "int64")
    want = Cast(Arith("sub", wide, c(win(0))), "int32")
    assert lf._plan == sorted_with([(win(0), lag(arg(0), 1))], want, [(arg(0), wide)])
    assert lf.schema["r"] == pa.int32()


def test_diff_of_zero_rows_is_the_column_less_itself():
    lf = frame().sort("id").with_columns(kpl.col("x").diff(0).alias("r"))
    assert lf._plan == Sort(Project(T, ALL + (("r", Arith("sub", c("x"), c("x"))),)), ID_ORDER)


# ---- refusals ----------------------------------------------------------------------


def test_shift_and_diff_of_an_unsorted_frame_are_refused_by_name():
    refused(lambda: frame().with_columns(kpl.col("x").shift(1)), UnsupportedOperation,
            NOT_SORTED.format(what="shift(1)"))
    refused(lambda: frame().with_columns(kpl.col("x").shift(-1)), UnsupportedOperation,
            NOT_SORTED.format(what="shift(-1)"))
    refused(lambda: frame().with_columns(kpl.col("x").diff()), UnsupportedOperation,
            NOT_SORTED.format(what="diff(1)"))


def test_the_arguments_polars_has_and_komira_does_not_build_are_refused():
    refused(lambda: kpl.col("x").shift(1, fill_value=0), UnsupportedOperation,
            "shift: fill_value= is not supported; a row with no row to read is null")
    refused(lambda: kpl.col("x").diff(1, null_behavior="drop"), UnsupportedOperation,
            "diff: null_behavior='drop' leaves out the first rows, which changes the number of rows; "
            "only null_behavior='ignore' is supported")
    refused(lambda: kpl.col("x").diff(1, null_behavior="keep"), ValueError,
            "diff: null_behavior must be 'ignore' or 'drop', not 'keep'")
    for verb in ("shift", "diff"):
        refused(lambda: getattr(kpl.col("x"), verb)(1.0), TypeError,
                f"{verb}: n must be an int, the number of rows, not float")
        refused(lambda: getattr(kpl.col("x"), verb)(True), TypeError,
                f"{verb}: n must be an int, the number of rows, not bool")
        refused(lambda: getattr(kpl.col("x").sum(), verb)(), UnsupportedOperation,
                f"{verb}: 'x' is already an aggregate; an aggregate of an aggregate is not supported")


def test_a_column_type_the_windows_do_not_read_is_refused_with_the_cast():
    ordered = frame().sort("id")
    refused(lambda: ordered.with_columns(kpl.col("flag").shift()), UnsupportedOperation,
            "shift of a column of type bool is not supported yet; cast it to int64, float64 or string")
    refused(lambda: ordered.with_columns(kpl.col("u16").shift()), UnsupportedOperation,
            "shift of a column of type uint16 is not supported yet; cast it to int64, float64 or string")
    refused(lambda: ordered.with_columns(kpl.col("g").diff()), UnsupportedOperation,
            "diff of a column of type string is not supported yet; cast it to int64 or float64")
    refused(lambda: ordered.with_columns(kpl.col("u16").diff()), UnsupportedOperation,
            "diff of a column of type uint16 is not supported yet; cast it to int64 or float64")


def test_collect_hands_the_session_plan_bytes_with_no_sql():
    lf = frame().sort("id").with_columns(kpl.col("x").shift(1).alias("p"), kpl.col("x").diff().alias("d"))
    SESSION.ran.clear()
    lf.collect()
    (plan,) = SESSION.ran
    for word in (b"SELECT", b"OVER"):
        assert word not in plan, word


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_shift: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
